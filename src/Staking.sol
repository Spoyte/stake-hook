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

contract Staking is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public feeGrowth0;
    mapping(PoolId => uint256 count) public feeGrowth1;

    uint32 lastTimestamp = 0;
    uint32 timeBetweenRewards = 1 minutes;
    uint32 rewardTime;
    bool deposited;
    address token;
    uint256 totalToken;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function deposit(
        address _token,
        uint256 _amountToken,
        uint32 _rewardTime
    ) external {
        require(!deposited, "already deposited");
        IERC20Minimal(_token).transferFrom(
            msg.sender,
            address(this),
            _amountToken
        );
        token = _token;
        rewardTime = _rewardTime;
        deposited = true;
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
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
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
        uint32 timeDuration = uint32(block.timestamp) - lastTimestamp;
        if (timeDuration > timeBetweenRewards) {
            lastTimestamp = uint32(block.timestamp);
            uint256 tokenAmount = (timeDuration * totalToken) / rewardTime;
            uint256 tokenAmount1 = tokenAmount / 2;
            uint256 tokenAmount2 = tokenAmount - tokenAmount1;
            feeGrowth0[key.toId()] += tokenAmount1;
            feeGrowth1[key.toId()] += tokenAmount2;
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
