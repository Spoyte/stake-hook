// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";

contract StakingLiquidity is BaseHook {
    using PoolIdLibrary for PoolKey;
    using Pool for Pool.State;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    struct StakingInfo {
        // token used to reward the staker
        address rewardToken;
        // Duration of rewards to be paid out (in seconds)
        uint256 duration;
        // Timestamp of when the rewards finish
        uint256 finishAt;
        // Minimum of last updated time and reward finish time
        uint256 updatedAt;
        // Reward to be paid out per second
        uint256 rewardRate;
        // Sum of (reward rate * dt * 1e18 / total supply)
        uint256 rewardPerTokenStored;
        // User address => rewardPerTokenStored
        mapping(address => uint256) userRewardPerTokenPaid;
        // User address => rewards to be claimed
        mapping(address => uint256) rewards;
        // Total staked
        uint256 totalSupply;
        // User address => staked amount
        mapping(address => uint256) balanceOf;
        bool init;
    }

    mapping(PoolId => StakingInfo) public StakingInfos;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier updateReward(PoolId _poolId, address _account) {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        stakingPoolInfo.rewardPerTokenStored = rewardPerToken(_poolId);
        stakingPoolInfo.updatedAt = lastTimeRewardApplicable(_poolId);

        if (_account != address(0)) {
            stakingPoolInfo.rewards[_account] = earned(_poolId, _account);
            stakingPoolInfo.userRewardPerTokenPaid[_account] = stakingPoolInfo
                .rewardPerTokenStored;
        }

        _;
    }

    function initialize(
        PoolId _poolId,
        address _rewardToken,
        uint256 _amount,
        uint32 _duration
    ) external {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        require(!stakingPoolInfo.init, "already inited");
        stakingPoolInfo.init = true;
        IERC20Minimal(_rewardToken).transferFrom(
            msg.sender,
            address(this),
            _amount
        );
        stakingPoolInfo.rewardToken = _rewardToken;
        stakingPoolInfo.duration = _duration;
        stakingPoolInfo.finishAt = block.timestamp + _duration;
        stakingPoolInfo.rewardRate = _amount / _duration;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata liquidityParams,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        updateReward(key.toId(), sender)
        returns (bytes4, BalanceDelta)
    {
        Position.Info memory positionInfo = StateLibrary.getPosition(
            poolManager,
            key.toId(),
            sender,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.salt
        );

        StakingInfo storage stakingPoolInfo = StakingInfos[key.toId()];
        stakingPoolInfo.balanceOf[msg.sender] += positionInfo.liquidity;
        stakingPoolInfo.totalSupply += positionInfo.liquidity;

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata liquidityParams,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        updateReward(key.toId(), sender)
        returns (bytes4, BalanceDelta)
    {
        Position.Info memory positionInfo = StateLibrary.getPosition(
            poolManager,
            key.toId(),
            sender,
            liquidityParams.tickLower,
            liquidityParams.tickUpper,
            liquidityParams.salt
        );

        StakingInfo storage stakingPoolInfo = StakingInfos[key.toId()];
        stakingPoolInfo.balanceOf[msg.sender] -= positionInfo.liquidity;
        stakingPoolInfo.totalSupply -= positionInfo.liquidity;

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    function lastTimeRewardApplicable(
        PoolId _poolId
    ) public view returns (uint256) {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        return _min(stakingPoolInfo.finishAt, block.timestamp);
    }

    function rewardPerToken(PoolId _poolId) public view returns (uint256) {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        if (stakingPoolInfo.totalSupply == 0) {
            return stakingPoolInfo.rewardPerTokenStored;
        }

        return
            stakingPoolInfo.rewardPerTokenStored +
            (stakingPoolInfo.rewardRate *
                (lastTimeRewardApplicable(_poolId) -
                    stakingPoolInfo.updatedAt) *
                1e18) /
            stakingPoolInfo.totalSupply;
    }

    function earned(
        PoolId _poolId,
        address _account
    ) public view returns (uint256) {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        return
            ((stakingPoolInfo.balanceOf[_account] *
                (rewardPerToken(_poolId) -
                    stakingPoolInfo.userRewardPerTokenPaid[_account])) / 1e18) +
            stakingPoolInfo.rewards[_account];
    }

    function getReward(
        PoolId _poolId
    ) external updateReward(_poolId, msg.sender) {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        uint256 reward = stakingPoolInfo.rewards[msg.sender];
        if (reward > 0) {
            stakingPoolInfo.rewards[msg.sender] = 0;
            IERC20Minimal(stakingPoolInfo.rewardToken).transfer(
                msg.sender,
                reward
            );
        }
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}
