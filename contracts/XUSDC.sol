// SPDX-License-Identifier: MIT
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/Ownable.sol";
import './libraries/TokenStructs.sol';
import './interfaces/FortubeToken.sol';
import './interfaces/FortubeBank.sol';
import './interfaces/IIEarnManager.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IVenus.sol';

contract xUSDC is ERC20, ReentrancyGuard, Ownable, TokenStructs {
  using SafeERC20 for IERC20;
  using Address for address;
  using SafeMath for uint256;

  uint256 public pool;
  address public token;
  address public apr;
  address public fortubeToken;
  address public fortubeBank;
  address public feeAddress;
  uint256 public feeAmount;
  address public venusToken;
  uint256 public feePrecision;

  mapping (address => uint256) depositedAmount;

  enum Lender {
      NONE,
      FORTUBE,
      VENUS
  }

  Lender public provider = Lender.NONE;

  constructor () public ERC20("xend USDC", "xUSDC") {

    token = address(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    apr = address(0xdD6d648C991f7d47454354f4Ef326b04025a48A8);
    fortubeToken = address(0xb2CB0Af60372E242710c42e1C34579178c3D2BED);
    fortubeBank = address(0x0cEA0832e9cdBb5D476040D58Ea07ecfbeBB7672);
    feeAddress = address(0x143afc138978Ad681f7C7571858FAAA9D426CecE);
    venusToken = address(0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8);
    feeAmount = 0;
    feePrecision = 1000;
    approveToken();
  }

  // Ownable setters incase of support in future for these systems
  function set_new_APR(address _new_APR) public onlyOwner {
      apr = _new_APR;
  }
  function set_new_feeAmount(uint256 fee) public onlyOwner{
    require(fee < feePrecision, 'fee amount must be less than 100%');
    feeAmount = fee;
  }
  function set_new_fee_address(address _new_fee_address) public onlyOwner {
      feeAddress = _new_fee_address;
  }
  function set_new_feePrecision(uint256 _newFeePrecision) public onlyOwner{
    assert(_newFeePrecision >= 100);
    set_new_feeAmount(feeAmount*_newFeePrecision/feePrecision);
    feePrecision = _newFeePrecision;
  }
  // Quick swap low gas method for pool swaps
  function deposit(uint256 _amount)
      external
      nonReentrant
  {
      require(_amount > 0, "deposit must be greater than 0");
      pool = _calcPoolValueInToken();
      IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
      rebalance();
      // Calculate pool shares
      uint256 shares = 0;
      if (pool == 0) {
        shares = _amount;
        pool = _amount;
      } else {
        if (totalSupply() == 0) {
          shares = _amount;
        } else {
          shares = (_amount.mul(totalSupply())).div(pool);
        }
      }
      pool = _calcPoolValueInToken();
      _mint(msg.sender, shares);
      depositedAmount[msg.sender] = depositedAmount[msg.sender].add(_amount);
      emit Deposit(msg.sender, _amount);
  }

  // No rebalance implementation for lower fees and faster swaps
  function withdraw(uint256 _shares)
      external
      nonReentrant
  {
      require(_shares > 0, "withdraw must be greater than 0");

      uint256 ibalance = balanceOf(msg.sender);
      require(_shares <= ibalance, "insufficient balance");

      // Could have over value from xTokens
      pool = _calcPoolValueInToken();
      uint256 i = (pool.mul(ibalance)).div(totalSupply());
      // Calc to redeem before updating balances
      uint256 r = (pool.mul(_shares)).div(totalSupply());
      if(i < depositedAmount[msg.sender]){
        i = i.add(1);
        r = r.add(1);
      }
      uint256 profit = (i.sub(depositedAmount[msg.sender])).mul(_shares.div(depositedAmount[msg.sender]));

      emit Transfer(msg.sender, address(0), _shares);

      // Check balance
      uint256 b = IERC20(token).balanceOf(address(this));
      if (b < r) {
        _withdrawSome(r.sub(b));
      }

      uint256 fee = profit.mul(feeAmount).div(feePrecision);
      if(fee > 0){
        IERC20(token).approve(feeAddress, fee);
        ITreasury(feeAddress).depositToken(token);
      }
      IERC20(token).safeTransfer(msg.sender, r.sub(fee));
      _burn(msg.sender, _shares);
      depositedAmount[msg.sender] = depositedAmount[msg.sender].sub(_shares.mul(depositedAmount[msg.sender]).div(ibalance));
      rebalance();
      pool = _calcPoolValueInToken();
      emit Withdraw(msg.sender, _shares);
  }

  receive() external payable {}

  function recommend() public returns (Lender) {
    (uint256 fapr, uint256 ftapr, uint256 vapr, uint256 aapr) = IIEarnManager(apr).recommend(token);
    uint256 max = 0;
    if (fapr > max) {
      max = fapr;
    }
    if (ftapr > max) {
      max = ftapr;
    }
    if (vapr > max) {
      max = vapr;
    }
    Lender newProvider = Lender.NONE;
    if (max == ftapr) {
      newProvider = Lender.FORTUBE;
    } else if (max == vapr) {
      newProvider = Lender.VENUS;
    }
    return newProvider;
  }

  function balance() public view returns (uint256) {
    return IERC20(token).balanceOf(address(this));
  }

  function getDepositedAmount(address investor) public view returns (uint256) {
    return depositedAmount[investor];
  }

  function approveToken() public {
      IERC20(token).approve(FortubeBank(fortubeBank).controller(),  uint(-1));
      IERC20(token).approve(venusToken, uint(-1));
  }
  function balanceFortubeInToken() public view returns (uint256) {
    uint256 b = balanceFortube();
    if (b > 0) {
      uint256 exchangeRate = FortubeToken(fortubeToken).exchangeRateStored();
      uint256 oneAmount = FortubeToken(fortubeToken).ONE();
      b = b.mul(exchangeRate).div(oneAmount);
    }
    return b;
  }
  function balanceVenusInToken() public view returns (uint256) {
    uint256 b = balanceVenus();
    if (b > 0) {
      uint256 exchangeRate = IVenus(venusToken).exchangeRateStored();
      b = b.mul(exchangeRate).div(10**28);
    }
    return b;
  }

  function balanceFortube() public view returns (uint256) {
    return FortubeToken(fortubeToken).balanceOf(address(this));
  }
  function balanceVenus() public view returns (uint256) {
    return IERC20(venusToken).balanceOf(address(this));
  }

  function _balance() internal view returns (uint256) {
    return IERC20(token).balanceOf(address(this));
  }

  function _balanceFortubeInToken() internal view returns (uint256) {
    uint256 b = balanceFortube();
    if (b > 0) {
      uint256 exchangeRate = FortubeToken(fortubeToken).exchangeRateStored();
      uint256 oneAmount = FortubeToken(fortubeToken).ONE();
      b = b.mul(exchangeRate).div(oneAmount);
    }
    return b;
  }

  function _balanceVenusInToken() internal view returns (uint256) {
    uint256 b = balanceVenus();
    if (b > 0) {
      uint256 exchangeRate = IVenus(venusToken).exchangeRateStored();
      b = b.mul(exchangeRate).div(10**28);
    }
    return b;

  }
  function _balanceFortube() internal view returns (uint256) {
    return IERC20(fortubeToken).balanceOf(address(this));
  }
  function _balanceVenus() internal view returns (uint256) {
    return IERC20(venusToken).balanceOf(address(this));
  }

  function _withdrawAll() internal {
    uint256  amount = _balanceFortube();
    if (amount > 0) {
      _withdrawFortube(amount);
    }
    amount = _balanceVenus();
    if (amount > 0) {
      _withdrawVenus(amount);
    }
  }

  function _withdrawSomeFortube(uint256 _amount) internal {
    uint256 b = balanceFortube();
    uint256 bT = balanceFortubeInToken();
    require(bT >= _amount, "insufficient funds");
    uint256 amount = (b.mul(_amount)).div(bT).add(1);
    _withdrawFortube(amount);
  }

function _withdrawSomeVenus(uint256 _amount) internal {
    uint256 b = balanceVenus();
    uint256 bT = _balanceVenusInToken();
    require(bT >= _amount, "insufficient funds");
    uint256 amount = (b.mul(_amount)).div(bT).add(1);
    _withdrawVenus(amount);
  }

  function _withdrawSome(uint256 _amount) internal {
    
    if (provider == Lender.FORTUBE) {
      _withdrawSomeFortube(_amount);
    }
    if (provider == Lender.VENUS) {
      _withdrawSomeVenus(_amount);
    }
  }

  function rebalance() public {
    Lender newProvider = recommend();

    if (newProvider != provider) {
      _withdrawAll();
    }

    if (balance() > 0) {
      if (newProvider == Lender.FORTUBE) {
        supplyFortube(balance());
      } else if (newProvider == Lender.VENUS) {
        supplyVenus(balance());
      }
    }

    provider = newProvider;
  }

  // Internal only rebalance for better gas in redeem
  function _rebalance(Lender newProvider) internal {
    if (_balance() > 0) {
      if (newProvider == Lender.FORTUBE) {
        supplyFortube(_balance());
      } else if (newProvider == Lender.VENUS) {
        supplyVenus(_balance());
      }
    }
    provider = newProvider;
  }

  function supplyFortube(uint amount) public {
      require(amount > 0, "FORTUBE: supply failed");
      FortubeBank(fortubeBank).deposit(token, amount);
  }
  function supplyVenus(uint amount) public {
      require(amount > 0, "VENUS: supply failed");
      IVenus(venusToken).mint(amount);
  }
  function _withdrawFortube(uint amount) internal {
      require(amount > 0, "FORTUBE: withdraw failed");
      FortubeBank(fortubeBank).withdraw(token, amount);
  }
  function _withdrawVenus(uint amount) internal {
      require(amount > 0, "VENUS: withdraw failed");
      IVenus(venusToken).redeem(amount);
  }
  function _calcPoolValueInToken() internal view returns (uint) {
    return _balanceFortubeInToken()
      .add(_balanceVenusInToken())
      .add(_balance());
  }

  function calcPoolValueInToken() public view returns (uint) {

    return balanceFortubeInToken()
      .add(balanceVenusInToken())
      .add(balance());
  }

  function getPricePerFullShare() public view returns (uint) {
    uint _pool = calcPoolValueInToken();
    return _pool.mul(1e18).div(totalSupply());
  }
}