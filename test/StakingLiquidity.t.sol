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
import {StakingLiquidity} from "../src/StakingLiquidity.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

contract StakingLiquidityTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    StakingLiquidity stakingHook;
    PoolId poolId;
    MockERC20 rewardToken;
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
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(StakingLiquidity).creationCode,
            abi.encode(address(manager))
        );
        stakingHook = new StakingLiquidity{salt: salt}(
            IPoolManager(address(manager))
        );
        require(
            address(stakingHook) == hookAddress,
            "StakingLiquidityTest: hook address mismatch"
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
        rewardToken = new MockERC20("reward", "RWD", 18);
        rewardToken.mint(address(this), amountToken);
        rewardToken.approve(address(stakingHook), amountToken);

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

        uint256 amount = stakingHook.earned(poolId, address(this));
        assertEq(amount, 0);

        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get some rewards
        amount = stakingHook.earned(poolId, bob);
        assertGt(amount, 0);
    }

    function testUserRemoveLiquidity() public {
        uint256 amount = stakingHook.earned(poolId, address(this));
        assertEq(amount, 0);

        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get some rewards
        amount = stakingHook.earned(poolId, bob);
        assertGt(amount, 0);

        uint256 liquidity = stakingHook.getLiquidity(poolId, alice);
        assertGt(liquidity, 0);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-120, 120, -1 ether, 0),
            abi.encode(alice)
        );

        uint256 newliquidity = stakingHook.getLiquidity(poolId, alice);
        assertLt(newliquidity, liquidity);
        console.log("lq %s new lq %s", liquidity, newliquidity);
    }

    function testUserWinSameAmount() public {
        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get same rewards if they are same liquidity
        uint256 rewardBob = stakingHook.earned(poolId, bob);
        uint256 rewardAlice = stakingHook.earned(poolId, alice);

        assertEq(rewardBob, rewardAlice);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(-120, 120, -1 ether, 0),
            abi.encode(alice)
        );

        // after alice remove some liquidity she wins less rewards than bob
        vm.warp(block.timestamp + 1 days);

        rewardBob = stakingHook.earned(poolId, bob);
        rewardAlice = stakingHook.earned(poolId, alice);
        assertGt(rewardBob, rewardAlice);
    }

    function testUserGetStake() public {
        vm.warp(block.timestamp + 31 days);

        uint256 rewardBob = stakingHook.earned(poolId, bob);
        address token = stakingHook.getRewardToken(poolId);
        uint256 balance = IERC20Minimal(token).balanceOf(bob);
        // bob didn't receive rewards
        assertEq(balance, 0);

        vm.prank(bob);
        stakingHook.getReward(poolId);

        // bob received all his rewards
        balance = IERC20Minimal(token).balanceOf(bob);
        console.log("reward %s balance %s", rewardBob, balance);
        assertEq(rewardBob, balance);

        vm.prank(bob);
        stakingHook.getReward(poolId);
        uint256 balanceNew = IERC20Minimal(token).balanceOf(bob);
        // bob didn't receive more token after the first claim
        assertEq(balanceNew, balance);
    }
}
