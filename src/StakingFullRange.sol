// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

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
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/src/libraries/CurrencySettleTake.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC6909} from "./ERC6909.sol";

contract StakingFullRange is BaseHook, IUnlockCallback, ERC6909 {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using StateLibrary for IPoolManager;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error LiquidityDoesntMeetMinimum();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

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
    }

    mapping(PoolId => StakingInfo) public StakingInfos;

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    mapping(PoolId => bool) public poolInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata data
    ) external override returns (bytes4) {
        (address _rewardToken, uint256 _amount, uint32 _duration) = abi.decode(
            data,
            (address, uint256, uint32)
        );
        require(_rewardToken != address(0), "No reward token defined");
        require(_amount > 0, "No reward token amount defined");
        StakingInfo storage stakingPoolInfo = StakingInfos[key.toId()];
        IERC20Minimal(_rewardToken).transferFrom(
            sender,
            address(this),
            _amount
        );
        stakingPoolInfo.rewardToken = _rewardToken;
        stakingPoolInfo.duration = _duration;
        stakingPoolInfo.finishAt = block.timestamp + _duration;
        stakingPoolInfo.rewardRate = _amount / _duration;

        return BaseHook.afterInitialize.selector;
    }

    function addLiquidity(
        AddLiquidityParams calldata params
    ) external ensure(params.deadline) returns (uint128 liquidity) {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: StakingFullRange(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        bool pool = poolInfo[poolId];

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }
        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            })
        );

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            _mint(
                address(0),
                uint256(PoolId.unwrap(poolId)),
                MINIMUM_LIQUIDITY
            );
        }

        _updateReward(poolId, params.to);

        _mint(params.to, uint256(PoolId.unwrap(poolId)), liquidity);

        StakingInfo storage stakingPoolInfo = StakingInfos[poolId];
        stakingPoolInfo.balanceOf[params.to] += liquidity;
        stakingPoolInfo.totalSupply += liquidity;

        if (
            uint128(-addedDelta.amount0()) < params.amount0Min ||
            uint128(-addedDelta.amount1()) < params.amount1Min
        ) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) public virtual ensure(params.deadline) returns (BalanceDelta delta) {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: StakingFullRange(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        delta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: 0
            })
        );

        _updateReward(poolId, msg.sender);

        _burn(msg.sender, uint256(PoolId.unwrap(poolId)), params.liquidity);

        StakingInfo storage stakingPoolInfo = StakingInfos[poolId];
        stakingPoolInfo.balanceOf[msg.sender] -= params.liquidity;
        stakingPoolInfo.totalSupply -= params.liquidity;
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        poolInfo[poolId] = false;

        return StakingFullRange.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return StakingFullRange.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        if (!poolInfo[poolId]) {
            poolInfo[poolId] = true;
        }

        return (
            StakingFullRange.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData(msg.sender, key, params))
            ),
            (BalanceDelta)
        );
    }

    function _settleDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        key.currency0.settle(
            poolManager,
            sender,
            uint256(int256(-delta.amount0())),
            false
        );
        key.currency1.settle(
            poolManager,
            sender,
            uint256(int256(-delta.amount1())),
            false
        );
    }

    function _takeDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        poolManager.take(
            key.currency0,
            sender,
            uint256(uint128(delta.amount0()))
        );
        poolManager.take(
            key.currency1,
            sender,
            uint256(uint128(delta.amount1()))
        );
    }

    function _removeLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        PoolId poolId = key.toId();

        if (poolInfo[poolId]) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            totalSupply[uint256(PoolId.unwrap(poolId))]
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta, ) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
        poolInfo[poolId] = false;
    }

    function unlockCallback(
        bytes calldata rawData
    )
        external
        override(IUnlockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta, ) = poolManager.modifyLiquidity(
                data.key,
                data.params,
                ZERO_BYTES
            );
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (FixedPointMathLib.sqrt(
            FullMath.mulDiv(
                uint128(balanceDelta.amount1()),
                FixedPoint96.Q96,
                uint128(balanceDelta.amount0())
            )
        ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)).toUint160();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: -MAX_INT - 1, // equivalent of type(int256).min
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            uint256(uint128(balanceDelta.amount0())),
            uint256(uint128(balanceDelta.amount1()))
        );

        (BalanceDelta balanceDeltaAfter, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(
            balanceDelta.amount0() + balanceDeltaAfter.amount0()
        );
        uint128 donateAmount1 = uint128(
            balanceDelta.amount1() + balanceDeltaAfter.amount1()
        );

        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }

    function _beforeTransfer(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) internal override returns (bool) {
        // update reward of sender & receiver on transfer
        PoolId poolId = PoolId.wrap(bytes32(id));
        _updateReward(poolId, sender);
        _updateReward(poolId, receiver);

        StakingInfo storage stakingPoolInfo = StakingInfos[poolId];
        stakingPoolInfo.balanceOf[sender] -= amount;
        stakingPoolInfo.balanceOf[receiver] += amount;
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

    function getReward(PoolId _poolId) external {
        _updateReward(_poolId, msg.sender);
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

    function getTotalSupply(PoolId _poolId) public view returns (uint256) {
        return StakingInfos[_poolId].totalSupply;
    }

    function getLiquidity(
        PoolId _poolId,
        address _account
    ) public view returns (uint256) {
        return StakingInfos[_poolId].balanceOf[_account];
    }

    function getRewardToken(PoolId _poolId) public view returns (address) {
        return StakingInfos[_poolId].rewardToken;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }

    function _updateReward(PoolId _poolId, address _account) private {
        StakingInfo storage stakingPoolInfo = StakingInfos[_poolId];
        stakingPoolInfo.rewardPerTokenStored = rewardPerToken(_poolId);
        stakingPoolInfo.updatedAt = lastTimeRewardApplicable(_poolId);

        if (_account != address(0)) {
            stakingPoolInfo.rewards[_account] = earned(_poolId, _account);
            stakingPoolInfo.userRewardPerTokenPaid[_account] = stakingPoolInfo
                .rewardPerTokenStored;
        }
    }
}
