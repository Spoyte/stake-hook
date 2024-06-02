// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StakingFullRange} from "../src/StakingFullRange.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract TestFullRange is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    event Initialize(
        PoolId poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    event ModifyPosition(
        PoolId indexed poolId,
        address indexed sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    );
    event Swap(
        PoolId indexed id,
        address sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int24 constant TICK_SPACING = 60;
    uint16 constant LOCKED_LIQUIDITY = 1000;
    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant MAX_TICK_LIQUIDITY = 11505069308564788430434325881101412;
    uint8 constant DUST = 30;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    uint160 flags =
        uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG
        );

    StakingFullRange stakingFullRangeHook;

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

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(StakingFullRange).creationCode,
            abi.encode(address(manager))
        );
        stakingFullRangeHook = new StakingFullRange{salt: salt}(
            IPoolManager(address(manager))
        );
        require(
            address(stakingFullRangeHook) == hookAddress,
            "StakingLiquidityTest: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            3000,
            60,
            IHooks(address(stakingFullRangeHook))
        );
        poolId = key.toId();

        // create the reward hook and deposit it on the hook
        rewardToken = new MockERC20("reward", "RWD", 18);
        rewardToken.mint(address(this), amountToken);
        rewardToken.approve(address(stakingFullRangeHook), amountToken);

        bytes memory dataInit = abi.encode(
            address(rewardToken),
            amountToken,
            uint32(30 days)
        );
        manager.initialize(key, SQRT_PRICE_1_1, dataInit);

        IERC20Minimal token0 = IERC20Minimal(Currency.unwrap(currency0));
        IERC20Minimal token1 = IERC20Minimal(Currency.unwrap(currency1));

        token0.approve(address(stakingFullRangeHook), type(uint256).max);
        token1.approve(address(stakingFullRangeHook), type(uint256).max);

        stakingFullRangeHook.addLiquidity(
            StakingFullRange.AddLiquidityParams(
                currency0,
                currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                bob,
                MAX_DEADLINE
            )
        );

        stakingFullRangeHook.addLiquidity(
            StakingFullRange.AddLiquidityParams(
                currency0,
                currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                alice,
                MAX_DEADLINE
            )
        );

        stakingFullRangeHook.addLiquidity(
            StakingFullRange.AddLiquidityParams(
                currency0,
                currency1,
                3000,
                30 ether,
                30 ether,
                29 ether,
                29 ether,
                dylan,
                MAX_DEADLINE
            )
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

        uint256 amount = stakingFullRangeHook.earned(poolId, bob);
        assertEq(amount, 0);

        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get some rewards
        amount = stakingFullRangeHook.earned(poolId, bob);
        assertGt(amount, 0);
    }

    function testUserRemoveLiquidity() public {
        uint256 amount = stakingFullRangeHook.earned(poolId, address(this));
        assertEq(amount, 0);

        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get some rewards
        amount = stakingFullRangeHook.earned(poolId, bob);
        assertGt(amount, 0);

        uint256 liquidity = stakingFullRangeHook.getLiquidity(poolId, alice);
        assertGt(liquidity, 0);

        StakingFullRange.RemoveLiquidityParams
            memory removeLiquidityParams = StakingFullRange
                .RemoveLiquidityParams(
                    currency0,
                    currency1,
                    3000,
                    60 ether,
                    MAX_DEADLINE
                );
        vm.startPrank(alice);
        stakingFullRangeHook.removeLiquidity(removeLiquidityParams);

        uint256 newliquidity = stakingFullRangeHook.getLiquidity(poolId, alice);
        assertLt(newliquidity, liquidity);
        uint256 tokenLiquidity = stakingFullRangeHook.balanceOf(
            alice,
            uint256(PoolId.unwrap(poolId))
        );
        // tokenliquidity equal liquidity owned by the user
        assertEq(tokenLiquidity, newliquidity);
        console.log("lq %s new lq %s", liquidity, newliquidity);
    }

    function testUserWinSameAmount() public {
        vm.warp(block.timestamp + 1 days);

        // after 1 days the user will get same rewards if they are same liquidity
        uint256 rewardBob = stakingFullRangeHook.earned(poolId, bob);
        uint256 rewardAlice = stakingFullRangeHook.earned(poolId, alice);

        assertApproxEqRel(rewardBob, rewardAlice, 0.4e18);

        StakingFullRange.RemoveLiquidityParams
            memory removeLiquidityParams = StakingFullRange
                .RemoveLiquidityParams(
                    currency0,
                    currency1,
                    3000,
                    10 ether,
                    MAX_DEADLINE
                );
        vm.startPrank(bob);
        stakingFullRangeHook.removeLiquidity(removeLiquidityParams);

        // after bob remove some liquidity she wins less rewards than alice
        vm.warp(block.timestamp + 1 days);

        rewardBob = stakingFullRangeHook.earned(poolId, bob);
        rewardAlice = stakingFullRangeHook.earned(poolId, alice);
        assertGt(rewardAlice, rewardBob);
    }

    function testUserGetStake() public {
        vm.warp(block.timestamp + 31 days);

        uint256 rewardBob = stakingFullRangeHook.earned(poolId, bob);
        address token = stakingFullRangeHook.getRewardToken(poolId);
        uint256 balance = IERC20Minimal(token).balanceOf(bob);
        // bob didn't receive rewards
        assertEq(balance, 0);

        vm.prank(bob);
        stakingFullRangeHook.getReward(poolId);

        // bob received all his rewards
        balance = IERC20Minimal(token).balanceOf(bob);
        console.log("reward %s balance %s", rewardBob, balance);
        assertEq(rewardBob, balance);

        vm.prank(bob);
        stakingFullRangeHook.getReward(poolId);
        uint256 balanceNew = IERC20Minimal(token).balanceOf(bob);
        // bob didn't receive more token after the first claim
        assertEq(balanceNew, balance);
    }
}
