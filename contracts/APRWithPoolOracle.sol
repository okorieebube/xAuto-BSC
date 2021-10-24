// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import "@openzeppelin/contracts/utils/Context.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/Ownable.sol";
import {ABDKMath64x64} from "./libraries/ABDKMath64x64.sol";

// Fulcrum
interface IFulcrum {
  function supplyInterestRate() external view returns (uint256);
  function nextSupplyInterestRate(uint256 supplyAmount) external view returns (uint256);
}

interface IFortube {
    function APY() external view returns (uint256);
}

interface IVenus {
  function supplyRatePerBlock() external view returns (uint);
}

interface IAlpaca {
  function vaultDebtVal() external view returns (uint256);
  function vaultDebtShare() external view returns (uint256);
  function totalSupply() external view returns (uint256);
  function totalToken() external view returns (uint256);
  function config() external view returns (address);
  function balanceOf(address _token) external view returns (uint256);
  function debtShareToVal(uint256 _amount) external view returns (uint256);
  function fairLaunchPoolId() external view returns (uint256);
  function token() external view returns (address);
}

interface IAlpacaFairLaunch {
  function alpacaPerBlock() external view returns (uint256);
  function poolInfo(uint256 index) external view returns (
    address stakeToken,
    uint256 allocPoint,
    uint256 lastRewardBlock,
    uint256 accAlpacaPerShare,
    uint256 accAlpacaPerShareTilBonusEnd
  );
  function totalAllocPoint() external view returns (uint256);
  function alpaca() external view returns (address);
}

interface IAlpacaConfig {
  function getFairLaunchAddr() external view returns (address);
  function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);
}

interface IUniswapV2Router02{
  function getAmountsOut(uint256 _amount, address[] calldata path) external view returns (uint256[] memory);
}

contract APRWithPoolOracle is Ownable {
  using SafeMath for uint256;
  using Address for address;

  address private usdtTokenAddress;
  address private wbnb;
  address private uniswapRouter;
  mapping (address => uint256) public alpacaTokenIndex;

  constructor() public {
    usdtTokenAddress = address(0x55d398326f99059fF775485246999027B3197955);
    wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    uniswapRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    alpacaTokenIndex[address(0x7C9e73d4C71dae564d41F78d56439bB4ba87592f)] = 3;
    alpacaTokenIndex[address(0x158Da805682BdC8ee32d52833aD41E74bb951E59)] = 16;
    alpacaTokenIndex[address(0xd7D069493685A581d27824Fc46EdA46B7EfC0063)] = 1;
  }
  function getFulcrumAPRAdjusted(address token, uint256 _supply) external view returns(uint256) {
    if(token == address(0))
      return 0;
    else
      return IFulcrum(token).nextSupplyInterestRate(_supply);
  }

  function getFortubeAPRAdjusted(address token) external view returns (uint256) {
    if(token == address(0))
      return 0;
    else{
      IFortube fortube = IFortube(token);
      return fortube.APY();
    }
  }

  function getVenusAPRAdjusted(address token) external view returns (uint256) {
    uint256 supplyRatePerBlock = IVenus(token).supplyRatePerBlock();
    int128 _temp = ABDKMath64x64.add(ABDKMath64x64.mul(ABDKMath64x64.divu(supplyRatePerBlock, 1e18),ABDKMath64x64.fromUInt(20*60*24)),ABDKMath64x64.fromUInt(1));
    return ABDKMath64x64.toUInt(ABDKMath64x64.sub(ABDKMath64x64.pow(_temp, 365),ABDKMath64x64.fromUInt(1)) * 1e18)*1e2;
  }

  function getAlpacaAPRAdjusted(address token) external view returns(uint256) {
    if(token == address(0))
      return 0;
    else{
      IAlpaca alpaca = IAlpaca(token);
      IAlpacaConfig config = IAlpacaConfig(alpaca.config());
      uint256 borrowInterest = config.getInterestRate(alpaca.vaultDebtVal(), alpaca.totalToken() - alpaca.vaultDebtVal()) * 356 * 24 * 3600;
      uint256 lendingApr = borrowInterest * alpaca.vaultDebtVal() / alpaca.totalToken() * (100 - 19) / 100;
      address fairLaunchAddr = config.getFairLaunchAddr();
      IAlpacaFairLaunch fairLaunch = IAlpacaFairLaunch(fairLaunchAddr);
      uint256 tokenIndex = alpacaTokenIndex[token];
      uint256 stakingApr = 0;
      {
        (, uint256 allocPoint, , ,) = fairLaunch.poolInfo(tokenIndex);
        uint256 alpacaTokenPrice = priceCheck(fairLaunch.alpaca(), usdtTokenAddress, 1e18);
        uint256 tokenPrice = priceCheck(alpaca.token(), usdtTokenAddress, 1e18);
        uint256 perBlock = fairLaunch.alpacaPerBlock();
        uint256 totalAllocPoint = fairLaunch.totalAllocPoint();
        uint256 debtShareToVal = alpaca.debtShareToVal(1e4);
        stakingApr = perBlock * allocPoint / totalAllocPoint * 20 * 60 * 24 * 365 / 1e18 * alpacaTokenPrice / (alpaca.balanceOf(fairLaunchAddr) / 1e18);
        stakingApr = stakingApr.mul(1e4).div(debtShareToVal).mul(1e18).div(tokenPrice);
      }
      uint256 apr = lendingApr + stakingApr;
      return 
        ABDKMath64x64.mulu(
          ABDKMath64x64.sub(
            ABDKMath64x64.exp(ABDKMath64x64.div(ABDKMath64x64.fromUInt(apr), ABDKMath64x64.fromUInt(1e18))),
            ABDKMath64x64.fromUInt(1)
          ),
          1e18
        )*1e2;
    }
  }

  
  function priceCheck(address start, address end, uint256 _amount) public view returns (uint256) {
    if (_amount == 0) {
      return 0;
    }

    address[] memory path;
    if (start == wbnb) {
      path = new address[](2);
      path[0] = wbnb;
      path[1] = end;
    } else {
      path = new address[](3);
      path[0] = start;
      path[1] = wbnb;
      path[2] = end;
    }

    uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).getAmountsOut(_amount, path);
    // [0x8f0528ce5ef7b51152a59745befdd91d97091d2f, 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 0x55d398326f99059fF775485246999027B3197955]
    return amounts[amounts.length - 1];
  }

  function setAlpacaTokenIndex(address _token, uint256 _index) public onlyOwner{
    alpacaTokenIndex[_token] = _index;
  }
}