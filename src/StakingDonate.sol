// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

contract StakingDonate is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public feeGrowth0;
    mapping(PoolId => uint256 count) public feeGrowth1;
    struct StakingInfo {
        uint256 lastTimestamp;
        uint256 timeBetweenRewards;
        uint256 rewardTime;
        address token;
        uint256 totalToken;
        bool isCurrency0;
    }

    mapping(PoolId => StakingInfo) public StakingInfos;

    bytes internal constant ZERO_BYTES = bytes("");

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata data
    ) external override returns (bytes4) {
        (address _token, uint256 _amount, uint32 _rewardTime) = abi.decode(
            data,
            (address, uint256, uint32)
        );
        Currency _currency = Currency.wrap(_token);
        require((_currency == key.currency0) || (_currency == key.currency1), "No reward token defined");
        require(_amount > 0, "No reward token amount defined");
        StakingInfo storage stakingPoolInfo = StakingInfos[key.toId()];
        IERC20Minimal(_token).transferFrom(
            sender,
            address(this),
            _amount
        );
        stakingPoolInfo.lastTimestamp = block.timestamp;
        stakingPoolInfo.timeBetweenRewards = 1 minutes;
        stakingPoolInfo.rewardTime = _rewardTime;
        stakingPoolInfo.token = _token;
        stakingPoolInfo.totalToken = _amount;
        stakingPoolInfo.isCurrency0 = (_currency == key.currency0);

        return BaseHook.afterInitialize.selector;
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
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
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
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        StakingInfo storage stakingPoolInfo = StakingInfos[key.toId()];
        uint256 timeDuration = block.timestamp - stakingPoolInfo.lastTimestamp;
        if (timeDuration > stakingPoolInfo.timeBetweenRewards) {
            stakingPoolInfo.lastTimestamp = uint32(block.timestamp);
            uint256 tokenAmount = (timeDuration * stakingPoolInfo.totalToken) / stakingPoolInfo.rewardTime;
            poolManager.donate(key, tokenAmount, 0, ZERO_BYTES);
            // uint256 tokenAmount1 = tokenAmount / 2;
            // uint256 tokenAmount2 = tokenAmount - tokenAmount1;
            // feeGrowth0[key.toId()] += tokenAmount1;
            // feeGrowth1[key.toId()] += tokenAmount2;
        }
        return (BaseHook.afterSwap.selector, 0);
    }
}
