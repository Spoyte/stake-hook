// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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

    PoolId id;

    PoolKey key2;
    PoolId id2;

    // For a pool that gets initialized with liquidity in setUp()
    PoolKey keyWithLiq;
    PoolId idWithLiq;

    MockERC20 rewardToken;
    uint256 amountToken = 1_000_000 * 10 ** 18;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address dylan = makeAddr("dylan");

    function setUp() public {
        deployFreshManagerAndRouters();

        MockERC20[] memory tokens = deployTokens(3, 2 ** 128);
        token0 = tokens[0];
        token1 = tokens[1];
        token2 = tokens[2];

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(StakingFullRange).creationCode,
            abi.encode(address(manager))
        );
        stakingFullRangeHook = new StakingFullRange{salt: salt}(
            IPoolManager(address(manager))
        );
        key = createPoolKey(token0, token1);
        id = key.toId();

        key2 = createPoolKey(token1, token2);
        id2 = key.toId();

        keyWithLiq = createPoolKey(token0, token2);
        idWithLiq = keyWithLiq.toId();

        token0.approve(address(stakingFullRangeHook), type(uint256).max);
        token1.approve(address(stakingFullRangeHook), type(uint256).max);
        token2.approve(address(stakingFullRangeHook), type(uint256).max);

        // create the reward hook and deposit it on the hook
        rewardToken = new MockERC20("reward", "RWD", 18);
        rewardToken.mint(address(this), amountToken);
        rewardToken.approve(address(stakingFullRangeHook), amountToken);

        bytes memory dataInit = abi.encode(
            address(rewardToken),
            amountToken,
            uint32(30 days)
        );

        initPool(
            keyWithLiq.currency0,
            keyWithLiq.currency1,
            stakingFullRangeHook,
            3000,
            SQRT_PRICE_1_1,
            dataInit
        );
        stakingFullRangeHook.addLiquidity(
            StakingFullRange.AddLiquidityParams(
                keyWithLiq.currency0,
                keyWithLiq.currency1,
                3000,
                100 ether,
                100 ether,
                99 ether,
                99 ether,
                address(this),
                MAX_DEADLINE
            )
        );
    }

    function testFullRange_beforeInitialize_AllowsPoolCreation() public {
        PoolKey memory testKey = key;

        vm.expectEmit(true, true, true, true);
        emit Initialize(
            id,
            testKey.currency0,
            testKey.currency1,
            testKey.fee,
            testKey.tickSpacing,
            testKey.hooks
        );

        snapStart("FullRangeInitialize");
        manager.initialize(testKey, SQRT_PRICE_1_1, ZERO_BYTES);
        snapEnd();

        uint256 liquidityToken = stakingFullRangeHook.balanceOf(
            address(this),
            uint256(PoolId.unwrap(id))
        );

        assertFalse(liquidityToken == 0);
    }

    function testFullRange_beforeInitialize_RevertsIfWrongSpacing() public {
        PoolKey memory wrongKey = PoolKey(
            key.currency0,
            key.currency1,
            0,
            TICK_SPACING + 1,
            stakingFullRangeHook
        );

        vm.expectRevert(StakingFullRange.TickSpacingNotDefault.selector);
        manager.initialize(wrongKey, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function testFullRange_addLiquidity_InitialAddSucceeds() public {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        StakingFullRange.AddLiquidityParams
            memory addLiquidityParams = StakingFullRange.AddLiquidityParams(
                key.currency0,
                key.currency1,
                3000,
                10 ether,
                10 ether,
                9 ether,
                9 ether,
                address(this),
                MAX_DEADLINE
            );

        snapStart("FullRangeAddInitialLiquidity");
        stakingFullRangeHook.addLiquidity(addLiquidityParams);
        snapEnd();

        bool hasAccruedFees = stakingFullRangeHook.poolInfo(id);
        uint256 liquidityTokenBal = stakingFullRangeHook.balanceOf(
            address(this),
            uint256(PoolId.unwrap(id))
        );

        assertEq(
            manager.getLiquidity(id),
            liquidityTokenBal + LOCKED_LIQUIDITY
        );

        assertEq(
            key.currency0.balanceOf(address(this)),
            prevBalance0 - 10 ether
        );
        assertEq(
            key.currency1.balanceOf(address(this)),
            prevBalance1 - 10 ether
        );

        assertEq(liquidityTokenBal, 10 ether - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, false);
    }

    function testFullRange_BeforeModifyPositionFailsWithWrongMsgSender()
        public
    {
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        vm.expectRevert(StakingFullRange.SenderMustBeHook.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: 100,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function createPoolKey(
        MockERC20 tokenA,
        MockERC20 tokenB
    ) internal view returns (PoolKey memory) {
        if (address(tokenA) > address(tokenB))
            (tokenA, tokenB) = (tokenB, tokenA);
        return
            PoolKey(
                Currency.wrap(address(tokenA)),
                Currency.wrap(address(tokenB)),
                3000,
                TICK_SPACING,
                stakingFullRangeHook
            );
    }
}
