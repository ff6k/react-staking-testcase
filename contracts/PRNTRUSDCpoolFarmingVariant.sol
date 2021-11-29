pragma solidity ^0.8.0;

// SPDX-License-Identifier: BSD-3-Clause
import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import "./interfaces/IUniswapRouterETH.sol";

contract PRNTRUSDCpoolFarmingVariant is Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    event RewardsTransferred(address holder, uint amount);
    event RewardsDisbursed(uint amount);

    // deposit token contract address and reward token contract address
    // these contracts are "trusted" and checked to not contain re-entrancy pattern
    // to safely avoid checks-effects-interactions where needed to simplify logic
    // PAPR BUSD LP Tokens / Farming tokens
    address public constant trustedDepositTokenAddress = 0x3fD5D987eee6b6d5E590835DA55a12cf5658307d;
    // Earned Tokens address : PRNTR
    address public constant trustedRewardTokenAddress = 0xB7F7644f999D34fB58cE91b3dBc26B0Bf7081337;
    
    address public constant prntr = 0x87D0935BA88e461eF3b2953fAA51E72282b21df6;
    address public constant unirouter = 0xff0d4e7112053C8Aa469E86717209A39686C17ab;

    // Amount of tokens
    uint public constant disburseAmount = 40000e18;
    uint256 private constant MAX_INT = 2**256 - 1;
    // To be disbursed continuously over this duration
    uint public constant disburseDuration = 730 days;

    // If there are any undistributed or unclaimed tokens left in contract after this time
    // Admin can claim them
    uint public constant adminCanClaimAfter = 1 minutes;


    // do not change this => disburse 100% rewards over `disburseDuration`
    uint public constant disbursePercentX100 = 100e2;

    uint public contractDeployTime;
    uint public adminClaimableTime;
    uint public lastDisburseTime;
    address[] public usdcToPRNTRRoute;

    uint public totalClaimedRewards = 0;

    EnumerableSet.AddressSet private holders;

    mapping (address => uint) public depositedTokens;
    mapping (address => uint) public depositTime;
    mapping (address => uint) public lastClaimedTime;
    mapping (address => uint) public totalEarnedTokens;
    // 1 address and 1 integer that returns the rewards the last time you claimed
    mapping (address => uint) public lastDivPoints;
    

    uint public totalTokensDisbursed = 0;
    uint public contractBalance = 0;
    uint public totalDivPoints = 0;
    uint public totalTokens = 0;
    uint internal constant pointMultiplier = 1e18;
    uint256 public slippage;

    event Slippage(uint256 slippage);

    constructor() public {
        contractDeployTime = block.timestamp;
        adminClaimableTime = contractDeployTime.add(adminCanClaimAfter);
        lastDisburseTime = contractDeployTime;
        usdcToPRNTRRoute = [trustedRewardTokenAddress, prntr];
        slippage = 99;
        _giveAllowances();
    }

    function setSlippage(uint256 _slippage) public onlyOwner {
        require(_slippage > 50, 'Too high ser');
        slippage = _slippage;
        emit Slippage(_slippage);
    }

    function addContractBalance(uint amount) public onlyOwner {
        IERC20(trustedRewardTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        contractBalance = contractBalance.add(amount);
    }
    //Frontend function for users estimated PRNTR out
    function getAmountOut(uint256 _amount) public view returns (uint256 amount) {
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(trustedDepositTokenAddress).getReserves();
        (uint256 amountOut) = IUniswapRouterETH(unirouter).getAmountOut(_amount, reserve1, reserve0);
        return amountOut;
    }

    function swapToPRNTR(uint256 _amount) internal {
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(trustedDepositTokenAddress).getReserves();
        (uint256 amountOut) = IUniswapRouterETH(unirouter).getAmountOut(_amount, reserve1, reserve0);
        IUniswapRouterETH(unirouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, amountOut.mul(slippage).div(100), usdcToPRNTRRoute, address(this), block.timestamp);
    }

    function updateAccount(address account) private {
        disburseTokens();
        uint pendingDivs = getPendingDivs(account);
        //we get some PRNTR at current rate
        uint256 prntrBalBeforeSwap = IERC20(prntr).balanceOf(address(this));

        if (pendingDivs > 0) {
            swapToPRNTR(pendingDivs);
            uint256 prntrBal = IERC20(prntr).balanceOf(address(this)).sub(prntrBalBeforeSwap);
            lastDivPoints[account] = totalDivPoints;
            IERC20(prntr).safeTransfer(account, prntrBal);
            totalEarnedTokens[account] = totalEarnedTokens[account].add(pendingDivs);
            totalClaimedRewards = totalClaimedRewards.add(pendingDivs);
            emit RewardsTransferred(account, pendingDivs);
        }
        lastClaimedTime[account] = block.timestamp;
        
    }
    // Used for calculating when withdrawing
    function getPendingDivs(address _holder) public view returns (uint) {
        if (!holders.contains(_holder)) return 0;
        if (depositedTokens[_holder] == 0) return 0;

        uint newDivPoints = totalDivPoints.sub(lastDivPoints[_holder]);

        uint depositedAmount = depositedTokens[_holder];

        uint pendingDivs = depositedAmount.mul(newDivPoints).div(pointMultiplier);

        return pendingDivs;
    }
    //Used for the front end
    function getEstimatedPendingDivs(address _holder) public view returns (uint) {
        uint pendingDivs = getPendingDivs(_holder);
        uint pendingDisbursement = getPendingDisbursement();
        if (contractBalance < pendingDisbursement) {
            pendingDisbursement = contractBalance;
        }
        uint depositedAmount = depositedTokens[_holder];
        if (depositedAmount == 0) return 0;
        if (totalTokens == 0) return 0;

        uint myShare = depositedAmount.mul(pendingDisbursement).div(totalTokens);

        return pendingDivs.add(myShare);
    }

    function getNumberOfHolders() public view returns (uint) {
        return holders.length();
    }


    function deposit(uint amountToDeposit) public {
        require(amountToDeposit > 0, "Cannot deposit 0 Tokens");

        IERC20(trustedDepositTokenAddress).safeTransferFrom(msg.sender, address(this), amountToDeposit);

        depositedTokens[msg.sender] = depositedTokens[msg.sender].add(amountToDeposit);
        totalTokens = totalTokens.add(amountToDeposit);

        if (!holders.contains(msg.sender)) {
            holders.add(msg.sender);
            depositTime[msg.sender] = block.timestamp;
        }
    }

    function withdraw(uint amountToWithdraw) public nonReentrant {
        require(amountToWithdraw > 0, "Cannot withdraw 0 Tokens!");

        require(depositedTokens[msg.sender] >= amountToWithdraw, "Invalid amount to withdraw");

        updateAccount(msg.sender);
        depositedTokens[msg.sender] = depositedTokens[msg.sender].sub(amountToWithdraw);
        IERC20(trustedDepositTokenAddress).safeTransfer(msg.sender, amountToWithdraw);
        totalTokens = totalTokens.sub(amountToWithdraw);

        if (holders.contains(msg.sender) && depositedTokens[msg.sender] == 0) {
            holders.remove(msg.sender);
        }
    }

    // withdraw without caring about Rewards
    function emergencyWithdraw(uint amountToWithdraw) public nonReentrant {
        require(amountToWithdraw > 0, "Cannot withdraw 0 Tokens!");

        require(depositedTokens[msg.sender] >= amountToWithdraw, "Invalid amount to withdraw");

        // manual update account here without withdrawing pending rewards
        disburseTokens();
        lastClaimedTime[msg.sender] = block.timestamp;
        lastDivPoints[msg.sender] = totalDivPoints;
        depositedTokens[msg.sender] = depositedTokens[msg.sender].sub(amountToWithdraw);
        totalTokens = totalTokens.sub(amountToWithdraw);

        IERC20(trustedDepositTokenAddress).safeTransfer(msg.sender, amountToWithdraw);

        if (holders.contains(msg.sender) && depositedTokens[msg.sender] == 0) {
            holders.remove(msg.sender);
        }
    }

    function claim() public nonReentrant {
        updateAccount(msg.sender);
    }

    function disburseTokens() private {
        uint amount = getPendingDisbursement();

        if (contractBalance < amount) {
            amount = contractBalance;
        }
        if (amount == 0 || totalTokens == 0) return;

        totalDivPoints = totalDivPoints.add(amount.mul(pointMultiplier).div(totalTokens));
        emit RewardsDisbursed(amount);

        contractBalance = contractBalance.sub(amount);
        lastDisburseTime = block.timestamp;

    }

    function getPendingDisbursement() public view returns (uint) {
        uint timeDiff;
        uint _now = block.timestamp;
        uint _stakingEndTime = contractDeployTime.add(disburseDuration);
        if (_now > _stakingEndTime) {
            _now = _stakingEndTime;
        }
        if (lastDisburseTime >= _now) {
            timeDiff = 0;
        } else {
            timeDiff = _now.sub(lastDisburseTime);
        }

        uint pendingDisburse = disburseAmount
                                    .mul(disbursePercentX100)
                                    .mul(timeDiff)
                                    .div(disburseDuration)
                                    .div(10000);
        return pendingDisburse;
    }

    function getDepositorsList(uint startIndex, uint endIndex)
        public
        view
        returns (address[] memory stakers,
            uint[] memory stakingTimestamps,
            uint[] memory lastClaimedTimeStamps,
            uint[] memory stakedTokens) {
        require (startIndex < endIndex);

        uint length = endIndex.sub(startIndex);
        address[] memory _stakers = new address[](length);
        uint[] memory _stakingTimestamps = new uint[](length);
        uint[] memory _lastClaimedTimeStamps = new uint[](length);
        uint[] memory _stakedTokens = new uint[](length);

        for (uint i = startIndex; i < endIndex; i = i.add(1)) {
            address staker = holders.at(i);
            uint listIndex = i.sub(startIndex);
            _stakers[listIndex] = staker;
            _stakingTimestamps[listIndex] = depositTime[staker];
            _lastClaimedTimeStamps[listIndex] = lastClaimedTime[staker];
            _stakedTokens[listIndex] = depositedTokens[staker];
        }

        return (_stakers, _stakingTimestamps, _lastClaimedTimeStamps, _stakedTokens);
    }

     function _giveAllowances() internal {
        IERC20(trustedRewardTokenAddress).safeApprove(unirouter, 0);
        IERC20(trustedRewardTokenAddress).safeApprove(unirouter, MAX_INT);
    }

    // function to allow owner to claim *other* modern ERC20 tokens sent to this contract
    function transferAnyERC20Token(address _tokenAddr, address _to, uint _amount) public onlyOwner {
        // require(_tokenAddr != trustedRewardTokenAddress && _tokenAddr != trustedDepositTokenAddress, "Cannot send out reward tokens or staking tokens!");

        require(_tokenAddr != trustedDepositTokenAddress, "Admin cannot transfer out deposit tokens from this vault!");
        require((_tokenAddr != trustedRewardTokenAddress) || (block.timestamp > adminClaimableTime), "Admin cannot Transfer out Reward Tokens Yet!");
        IERC20(_tokenAddr).safeTransfer(_to, _amount);
    }
}