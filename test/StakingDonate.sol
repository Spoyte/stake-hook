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
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

contract StakingDonateTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    StakingDonate stakingHook;
    PoolId poolId;
    // MockERC20 rewardToken;
    uint256 amountToken = 1_000_000 * 10 ** 18;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address dylan = makeAddr("dylan");

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(StakingDonate).creationCode,
            abi.encode(address(manager))
        );
        stakingHook = new StakingDonate{salt: salt}(
            IPoolManager(address(manager))
        );
        require(
            address(stakingHook) == hookAddress,
            "StakingDonateTest: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            3000,
            60,
            IHooks(address(stakingHook))
        );
        poolId = key.toId();

        // create the reward hook and deposit it on the hook
        address rewardToken = Currency.unwrap(currency0);
        // rewardToken.mint(address(this), amountToken);
        IERC20Minimal(rewardToken).approve(address(stakingHook), amountToken);

        bytes memory dataInit = abi.encode(
            address(rewardToken),
            amountToken,
            uint32(30 days)
        );
        manager.initialize(key, SQRT_PRICE_1_1, dataInit);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, 0),
            abi.encode(bob)
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, 0),
            abi.encode(alice)
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                3 ether,
                0
            ),
            abi.encode(dylan)
        );
    }

    function testLiquidityHooksEarn() public {
        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        //uint256 amount = stakingHook.earned(poolId, address(this));
        //assertEq(amount, 0);

        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get some rewards
        // amount = stakingHook.earned(poolId, bob);
        // assertGt(amount, 0);
    }

}