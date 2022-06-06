// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IAstralPlane.sol";

contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0xB7e1E341b2CBCc7d1EdF4DC6E5e962aE5C621ca5), // GrapeGenesisRewardPool
        address(0x04b79c851ed1A36549C6151189c79EC0eaBca745) // GrapeRewardPool
    ];

    // core components
    address public galaxy;
    address public gbond;
    address public gshare;

    address public astralplane;
    address public galaxyOracle;

    // price
    uint256 public galaxyPriceOne;
    uint256 public galaxyPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of GLXY price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochGalaxyPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra GLXY during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 galaxyAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 galaxyAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getGalaxyPrice() > galaxyPriceCeiling) ? 0 : getGalaxyCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(galaxy).operator() == address(this) &&
                IBasisAsset(gbond).operator() == address(this) &&
                IBasisAsset(gshare).operator() == address(this) &&
                Operator(astralplane).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getGalaxyPrice() public view returns (uint256 galaxyPrice) {
        try IOracle(galaxyOracle).consult(galaxy, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult galaxy price from the oracle");
        }
    }

    function getGalaxyUpdatedPrice() public view returns (uint256 _galaxyPrice) {
        try IOracle(galaxyOracle).twap(galaxy, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult galaxy price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableGalaxyLeft() public view returns (uint256 _burnableGalaxyLeft) {
        uint256 _galaxyPrice = getGalaxyPrice();
        if (_galaxyPrice <= galaxyPriceOne) {
            uint256 _galaxySupply = getGalaxyCirculatingSupply();
            uint256 _bondMaxSupply = _galaxySupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(gbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableGalaxy = _maxMintableBond.mul(_galaxyPrice).div(1e18);
                _burnableGalaxyLeft = Math.min(epochSupplyContractionLeft, _maxBurnableGalaxy);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _galaxyPrice = getGalaxyPrice();
        if (_galaxyPrice > galaxyPriceCeiling) {
            uint256 _totalGrape = IERC20(galaxy).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalGrape.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _galaxyPrice = getGalaxyPrice();
        if (_galaxyPrice <= galaxyPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = galaxyPriceOne;
            } else {
                uint256 _bondAmount = galaxyPriceOne.mul(1e18).div(_galaxyPrice); // to burn 1 GLXY
                uint256 _discountAmount = _bondAmount.sub(galaxyPriceOne).mul(discountPercent).div(10000);
                _rate = galaxyPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _galaxyPrice = getGalaxyPrice();
        if (_galaxyPrice > galaxyPriceCeiling) {
            uint256 _galaxyPricePremiumThreshold = galaxyPriceOne.mul(premiumThreshold).div(100);
            if (_galaxyPrice >= _galaxyPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _galaxyPrice.sub(galaxyPriceOne).mul(premiumPercent).div(10000);
                _rate = galaxyPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = galaxyPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _galaxy,
        address _gbond,
        address _gshare,
        address _galaxyOracle,
        address _astralplane,
        uint256 _startTime
    ) public notInitialized {
        galaxy = _galaxy;
        gbond = _gbond;
        gshare = _gshare;
        galaxyOracle = _galaxyOracle;
        astralplane = _astralplane;
        startTime = _startTime;

        galaxyPriceOne = 2.5*10**13; // This is to allow a PEG of 1 GLXY per MIM
        galaxyPriceCeiling = galaxyPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 10000 ether, 20000 ether, 30000 ether, 40000 ether, 50000 ether, 100000 ether, 200000 ether, 500000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for astralplane
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn GLXY and mint GBOND)
        maxDebtRatioPercent = 4000; // Upto 40% supply of GBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 14 epochs with 4.5% expansion
        bootstrapEpochs = 14;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(galaxy).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setAstralPlane(address _astralplane) external onlyOperator {
        astralplane = _astralplane;
    }

    function setGalaxyOracle(address _galaxyOracle) external onlyOperator {
        galaxyOracle = _galaxyOracle;
    }

    function setGalaxyPriceCeiling(uint256 _galaxyPriceCeiling) external onlyOperator {
        require(_galaxyPriceCeiling >= galaxyPriceOne && _galaxyPriceCeiling <= galaxyPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        galaxyPriceCeiling = _galaxyPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 2500, "out of range"); // <= 25%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 500, "out of range"); // <= 5%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= galaxyPriceCeiling, "_premiumThreshold exceeds galaxyPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateGalaxyPrice() internal {
        try IOracle(galaxyOracle).update() {} catch {}
    }

    function getGalaxyCirculatingSupply() public view returns (uint256) {
        IERC20 galaxyErc20 = IERC20(galaxy);
        uint256 totalSupply = galaxyErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(galaxyErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _galaxyAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_galaxyAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 galaxyPrice = getGalaxyPrice();
        require(galaxyPrice == targetPrice, "Treasury: GLXY price moved");
        require(
            galaxyPrice < galaxyPriceOne, // price < $1
            "Treasury: galaxyPrice not eligible for bond purchase"
        );

        require(_galaxyAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _galaxyAmount.mul(_rate).div(1e18);
        uint256 galaxySupply = getGalaxyCirculatingSupply();
        uint256 newBondSupply = IERC20(gbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= galaxySupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(galaxy).burnFrom(msg.sender, _galaxyAmount);
        IBasisAsset(gbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_galaxyAmount);
        _updateGalaxyPrice();

        emit BoughtBonds(msg.sender, _galaxyAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 galaxyPrice = getGalaxyPrice();
        require(galaxyPrice == targetPrice, "Treasury: GLXY price moved");
        require(
            galaxyPrice > galaxyPriceCeiling, // price > $1.01
            "Treasury: galaxyPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _galaxyAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(galaxy).balanceOf(address(this)) >= _galaxyAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _galaxyAmount));

        IBasisAsset(gbond).burnFrom(msg.sender, _bondAmount);
        IERC20(galaxy).safeTransfer(msg.sender, _galaxyAmount);

        _updateGalaxyPrice();

        emit RedeemedBonds(msg.sender, _galaxyAmount, _bondAmount);
    }

    function _sendToAstralPlane(uint256 _amount) internal {
        IBasisAsset(galaxy).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(galaxy).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(galaxy).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(galaxy).safeApprove(astralplane, 0);
        IERC20(galaxy).safeApprove(astralplane, _amount);
        IAstralPlane(astralplane).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _galaxySupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_galaxySupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateGalaxyPrice();
        previousEpochGalaxyPrice = getGalaxyPrice();
        uint256 galaxySupply = getGalaxyCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToAstralPlane(galaxySupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochGalaxyPrice > galaxyPriceCeiling) {
                // Expansion ($GLXY Price > 1 $MIM): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(gbond).totalSupply();
                uint256 _percentage = previousEpochGalaxyPrice.sub(galaxyPriceOne);
                uint256 _savedForBond;
                uint256 _savedForAstralPlane;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(galaxySupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForAstralPlane = galaxySupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = galaxySupply.mul(_percentage).div(1e18);
                    _savedForAstralPlane = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForAstralPlane);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForAstralPlane > 0) {
                    _sendToAstralPlane(_savedForAstralPlane);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(galaxy).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(galaxy), "galaxy");
        require(address(_token) != address(gbond), "bond");
        require(address(_token) != address(gshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function astralplaneSetOperator(address _operator) external onlyOperator {
        IAstralPlane(astralplane).setOperator(_operator);
    }

    function astralplaneSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IAstralPlane(astralplane).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function astralplaneAllocateSeigniorage(uint256 amount) external onlyOperator {
        IAstralPlane(astralplane).allocateSeigniorage(amount);
    }

    function astralplaneGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IAstralPlane(astralplane).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
