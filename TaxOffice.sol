// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";


contract TaxOffice is Operator {
    address public galaxy;

    constructor(address _galaxy) public {
        require(_galaxy != address(0), "galaxy address cannot be 0");
        galaxy = _galaxy;
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(galaxy).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(galaxy).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(galaxy).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(galaxy).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(galaxy).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(galaxy).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(galaxy).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(galaxy).excludeAddress(_address);
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(galaxy).includeAddress(_address);
    }

    function setTaxableGalaxyOracle(address _galaxyOracle) external onlyOperator {
        ITaxable(galaxy).setGalaxyOracle(_galaxyOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(galaxy).setTaxOffice(_newTaxOffice);
    }
}