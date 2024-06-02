// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {StakingDonate} from "../src/StakingDonate.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract StakingDonateTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    StakingDonate stakingDonate;
    PoolId poolId;
    // MockERC20 rewardToken;
    // uint256 amountToken = 1_000_000 * 10 ** 18;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StakingDonate).creationCode, abi.encode(address(manager)));
        stakingDonate = new StakingDonate{salt: salt}(IPoolManager(address(manager)));
        require(address(stakingDonate) == hookAddress, "StakingDonateTest: hook address mismatch");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(stakingDonate)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether, 0),
            ZERO_BYTES
        );
    }

    function testStakingDonateHooks() public {
        // positions were created in setup()
        // assertEq(stakingDonate.beforeAddLiquidityCount(poolId), 3);
        // assertEq(stakingDonate.beforeRemoveLiquidityCount(poolId), 0);

        // assertEq(stakingDonate.beforeSwapCount(poolId), 0);
        // assertEq(stakingDonate.afterSwapCount(poolId), 0);

        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        assertEq(stakingDonate.beforeSwapCount(poolId), 1);
        assertEq(stakingDonate.afterSwapCount(poolId), 1);
    }

    function testLiquidityHooks() public {
        // positions were created in setup()
        assertEq(stakingDonate.beforeAddLiquidityCount(poolId), 3);
        assertEq(stakingDonate.beforeRemoveLiquidityCount(poolId), 0);

        // remove liquidity
        int256 liquidityDelta = -1e18;
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-60, 60, liquidityDelta, 0), ZERO_BYTES
        );

        assertEq(stakingDonate.beforeAddLiquidityCount(poolId), 3);
        assertEq(stakingDonate.beforeRemoveLiquidityCount(poolId), 1);
    }
}
