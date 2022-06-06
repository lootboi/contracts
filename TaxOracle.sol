// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public galaxy;
    IERC20 public tri;
    address public pair;

    constructor(
        address _galaxy,
        address _tri,
        address _pair
    ) public {
        require(_galaxy != address(0), "galaxy address cannot be 0");
        require(_tri != address(0), "tri address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        galaxy = IERC20(_galaxy);
        tri = IERC20(_tri);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(galaxy), "token needs to be galaxy");
        uint256 galaxyBalance = galaxy.balanceOf(pair);
        uint256 triBalance = tri.balanceOf(pair);
        return uint144(galaxyBalance.mul(_amountIn).div(triBalance));
    }

    function getGalaxyBalance() external view returns (uint256) {
	return galaxy.balanceOf(pair);
    }

    function getTriBalance() external view returns (uint256) {
	return tri.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 galaxyBalance = galaxy.balanceOf(pair);
        uint256 triBalance = tri.balanceOf(pair);
        return galaxyBalance.mul(1e18).div(triBalance);
    }


    function setGalaxy(address _galaxy) external onlyOwner {
        require(_galaxy != address(0), "galaxy address cannot be 0");
        galaxy = IERC20(_galaxy);
    }

    function setTri(address _tri) external onlyOwner {
        require(_tri != address(0), "tri address cannot be 0");
        tri = IERC20(_tri);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }



}