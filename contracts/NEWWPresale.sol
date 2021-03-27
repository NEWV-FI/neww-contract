// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import './pancake/interface/IPancakeRouter02.sol';
import './pancake/interface/IPancakePair.sol';
import "./NEWWToken.sol";
import "./TimedCrowdsale.sol";
import "./pancake/interface/IPancakeFactory.sol";
import "./pancake/interface/IWETH.sol";
import "./interface/IFarmManager.sol";

interface IMintableERC20 is IERC20 {
    function mint(address, uint256) external;

    function transferOwnership(address) external;

    function burn(uint256 amount) external;
}

contract NEWWPresale is TimedCrowdsale, Ownable {
    using SafeERC20 for IMintableERC20;
    using SafeMath for uint256;

    struct addressStruct {
        uint256 purchasedAmount;
        uint256 purchasedTokenAmount;
        uint256 lastReleaseTime;
    }

    mapping(address => addressStruct) public purchasedAddress;

    uint256 private _storeValue;
    uint256 private _storeTokenValue;
    uint256 private _rateNEWW;
    uint256 private _hardCap;
    IMintableERC20 private _token;
    uint private _rawCloseTime;

    uint private _rateReduce;
    IPancakeRouter02 private _swapRouter;
    uint private _step;

    bool private _unlock;
    uint256 private _lastReleaseBlock;
    uint256 private _lastReleaseTimestamp;

    IFarmManager _farmManager;

    constructor(uint256 rate, IMintableERC20 token, address payable project, uint startTime, address router, address farmManager)
    TimedCrowdsale(startTime, startTime + 6 hours)
    Crowdsale(rate, project, token)
    public
    {
        require(startTime < closingTime(), "NEWWPresale:Time Breaking");
        _rateNEWW = rate;
        _token = token;
        _rawCloseTime = closingTime();
        _rateReduce = 100;
        _swapRouter = IPancakeRouter02(router);
        _unlock = false;
        _hardCap = 4000 * 1 ether;
        _farmManager = IFarmManager(farmManager);
    }

    function lastReleaseBlock() public view returns (uint256){
        return _lastReleaseBlock;
    }

    function storeAmount() public view returns (uint256, uint256){
        return (_storeValue, _storeTokenValue);
    }

    function rate() public view override returns (uint256) {
        return _rateNEWW.sub(_storeValue.div(1 ether).div(1000).mul(_rateReduce));
    }

    function _getTokenAmount(uint256 weiAmount) internal view override returns (uint256) {
        uint256 r = rate();
        require(r > 0, "NEWWPresale:can not any token now!");
        return weiAmount.mul(r);
    }

    /**
    * save get eth total
    */
    function _forwardFunds() internal override {
        _storeValue = _storeValue.add(msg.value);
        purchasedAddress[msg.sender].purchasedAmount += msg.value;
    }

    /**
    * check purchase condition
    */
    function _preValidatePurchase(address beneficiary, uint256 weiAmount) internal view override {
        super._preValidatePurchase(beneficiary, weiAmount);
        //hard cap
        require(_storeValue < _hardCap, "NEWWPresale:Hard Cap");
        //check the value after purchase
        //        require(_storeValue.add(weiAmount) < _hardCap, "NEWWPresale:Oops");
        // more than 1
        require(weiAmount > 1 ether, "NEWWPresale:Maybe buy little more?");
        // less than 5000
        require(addressPurchasedAmount(msg.sender) + weiAmount <= 100 ether, "NEWWPresale:Buy limit");
    }

    function addressPurchasedAmount(address addr) internal view returns (uint256){
        return purchasedAddress[addr].purchasedAmount;
    }

    function _updatePurchasingState(address, uint256 weiAmount) internal override {
        uint256 amount = _storeValue.add(weiAmount).div(1 ether);
        uint256 time = 0;
        time = amount.div(500).mul(1 hours);
        uint256 newTime = time.add(_rawCloseTime);
        if (newTime <= closingTime()) return;
        _extendTime(newTime);
    }

    /**
    * token
    */
    function _processPurchase(address beneficiary, uint256 tokenAmount) internal override {
        purchasedAddress[beneficiary].purchasedTokenAmount += tokenAmount;
        _storeTokenValue = _storeTokenValue.add(tokenAmount);
        emit PurchaseNEWW(beneficiary, tokenAmount);
    }

    event PurchaseNEWW(address indexed beneficiary, uint256 tokenAmount);

    event ReleaseNEWW(address indexed beneficiary, uint256 amount);

    function canRelease() public view returns (bool){
        return _unlock;
    }

    function release() public nonReentrant {
        require(_unlock == true, "NEWWPresale:Locking");

        addressStruct storage purchaseData = purchasedAddress[msg.sender];
        if (purchaseData.purchasedTokenAmount == 0) return;
        if (_lastReleaseTimestamp > purchaseData.lastReleaseTime) purchaseData.lastReleaseTime = _lastReleaseTimestamp;
        uint256 offset = block.timestamp.sub(purchaseData.lastReleaseTime).div(1 hours);

        uint256 amount = purchaseData.purchasedTokenAmount.div(100).mul(2).mul(offset);
        require(amount > 0, "NEWWPresale:Zero");
        if(purchaseData.purchasedTokenAmount < amount) amount = purchaseData.purchasedTokenAmount;
        purchaseData.purchasedTokenAmount = purchaseData.purchasedTokenAmount.sub(amount);
        purchaseData.lastReleaseTime = block.timestamp;

        _token.mint(msg.sender, amount);
        emit ReleaseNEWW(msg.sender, amount);
        return;
    }


    event UnlockRelease(uint block, address self);

    function afterClose() public onlyOwner nonReentrant {
        require(hasClosed(), "NEWWPresale:have not close");
        address payable project = this.wallet();

        uint256 totalToken = _storeTokenValue.div(4).mul(10);
        uint256 percentToken = totalToken.div(100);

        uint toMaster = percentToken.mul(10);
        uint toDao = percentToken.mul(36);
        uint toSwap = percentToken.mul(14);

        _token.mint(project, toMaster);
        _token.mint(project, toDao);

        uint256 last = _storeValue.div(2);
        project.transfer(last);
        last = _storeValue.sub(last);

        //to uniswap
        _token.mint(address(this), toSwap);
        _token.approve(address(_swapRouter), toSwap);
        //lock in contract address
        _swapRouter.addLiquidityETH{value : last}(address(_token), toSwap, toSwap, last, address(this), now);

        _unlock = true;
        _lastReleaseBlock = block.number;
        _lastReleaseTimestamp = block.timestamp;
        emit UnlockRelease(block.number, address(this));
    }

    event LiquidityRelease(uint amount);

    //daily release
    function board() public nonReentrant {
        require(_unlock, "NEWWPresale:been locked");
        require(block.number - 100 >= _lastReleaseBlock, "NEWWPresale:need 100 blocks space");

        uint256 offset = block.number - _lastReleaseBlock;
        _lastReleaseBlock = block.number;
        IPancakeFactory factory = IPancakeFactory(_swapRouter.factory());
        IPancakePair pair = IPancakePair(factory.getPair(address(_token), _swapRouter.WETH()));
        uint liq = pair.balanceOf(address(this));
        uint releaseAmount = liq.div(100000).mul(offset);
        // only 1%
        if (releaseAmount > liq.div(100)) releaseAmount = liq.div(100);

        require(releaseAmount > 0, "NEWWPresale:have not liquidity");
        pair.approve(address(_swapRouter), releaseAmount);
        //should be zero
        uint256 lastBalance = address(this).balance;
        _swapRouter.removeLiquidityETH(address(_token), releaseAmount, 0, 0, address(this), now);
        uint256 afterBalance = address(this).balance;
        uint256 offsetAmount = afterBalance - lastBalance;

        _farmManager.handleReceiveBNBToShare{value:offsetAmount}(offsetAmount);

        uint256 burn = IERC20(_token).balanceOf(address(this)).div(2);
        _token.burn(burn);
        _farmManager.handleReceiveNEWWFromShare(IERC20(_token).balanceOf(address(this)));

        emit LiquidityRelease(offset);
    }

    receive() external payable override {
        if (!hasClosed()) {
            buyTokens(msg.sender);
        }
    }

    function migrate(address payable receiver) onlyOwner public nonReentrant {
        _token.safeTransfer(receiver, _token.balanceOf(address(this)));
        _token.transferOwnership(receiver);
        Address.sendValue(receiver, address(this).balance);
        IPancakePair pair = IPancakePair(_swapRouter.factory());
        pair.transfer(receiver, pair.balanceOf(receiver));
    }

    //==============for pancake==============//

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'PancakeLibrary: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'PancakeLibrary: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) public pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'd0d4c4cd0848c93cb4fd1f498d7013ee6bfb25783ea21593d5834f5d250ece66' // init code hash
            ))));
    }
}


