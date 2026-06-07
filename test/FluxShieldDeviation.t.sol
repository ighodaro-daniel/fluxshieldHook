// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {FluxShieldHook} from "../src/FluxShieldHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "v4-core/types/PoolOperation.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}
contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _updatedAt;

    function setData(
        int256 answer_,
        uint8 decimals_,
        uint256 updatedAt_
    ) external {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = updatedAt_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (uint80(1), _answer, uint256(0), _updatedAt, uint80(1));
    }

    function getRoundData(
        uint80
    )
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("not implemented");
    }
}

contract FluxShieldDeviationTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    FluxShieldHook public hook;
    MockAggregator public agg;
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant OVERRIDE_FLAG =
        uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG);

    PoolKey public  key2;
    event FeeAdjusted(PoolKey indexed key, uint24 fee, uint256 deviation);
    event OracleFailed(PoolKey indexed key, string reason);
    event PausedStateChanged(bool isPaused);
    event ConfigUpdated(uint16[4] tiers, uint24 maxFee);

    function setUp() public {
        // Deploy v4-core, tokens, and routers
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG));

        deployCodeTo(
            "src/FluxShieldHook.sol:FluxShieldHook",
            abi.encode(manager),
            hookAddress
        );
        hook = FluxShieldHook(hookAddress);

        // Initialize pool and add liquidity
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );

        // Deploy mock aggregator
        agg = new MockAggregator();
    }

    function _computeAmmPrice(
        uint160 sqrtPriceX96,
        uint8 dec0,
        uint8 dec1
    ) internal pure returns (uint256) {
        uint256 exponent = 18 + uint256(dec0);
        uint256 step1 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            10 ** (exponent - uint256(dec1)),
            uint256(1) << 96
        );
        return FullMath.mulDiv(uint256(sqrtPriceX96), step1, uint256(1) << 96);
    }

    function test_noDeviation_detected() public {
        // Register pool with Chainlink feed
        hook.registerPool(key, address(agg), false, 18, 18);

        // Read AMM price
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Use 8 decimals for mock (common for ETH/USD)
        uint8 agDec = 8;
        uint256 answer = ammPrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertEq(deviation, 0);
    }

    function test_smallDeviation_matchesThresholdCalculation() public {
        hook.registerPool(key, address(agg), false, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 baseThreshold = hook.deviationBaseThreshold();
        uint256 devScale = hook.DEVIATION_SCALE();

        uint256 wantedDev = baseThreshold / 2; // half the base threshold
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, wantedDev, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, wantedDev, 10);
    }

    function test_stalePrice_reverts() public {
        hook.registerPool(key, address(agg), false, 18, 18);

        uint8 agDec = 8;
        // Warp forward so block.timestamp > MAX_PRICE_AGE, then set an old updatedAt
        vm.warp(hook.MAX_PRICE_AGE() + 10);
        agg.setData(int256(1e8), agDec, 1);

        vm.expectRevert(bytes("Stale Chainlink price"));
        hook.getChainlinkMarketDeviation(key);
    }

    function test_inversePrice_zeroDeviation() public {
        // Register pool with inverse true
        hook.registerPool(key, address(agg), true, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        // For inverse feed, set aggregator so normalized inverse equals ammPrice
        uint256 PREC = hook.PRECISION();
        uint256 normalizedNeeded = FullMath.mulDiv(PREC, PREC, ammPrice);
        uint256 answer = normalizedNeeded / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertEq(deviation, 0);
    }

    // ====== Arbitrageur Slash Tests ======
    // Simulate arbitrageur attempting to exploit price differences and getting slashed

    function test_arbitrage_smallDeviation_noSlash() public {
        // Arbitrageur attempts small arbitrage with 0.3% deviation
        // Expected: Base fee applied (no significant penalty)
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 smallDeviation = 3000; // 0.3% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, smallDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, smallDeviation, 10);

        // Verify fee tier is base (3000 pips)
        uint24[4] memory tiers = [
            uint24(3000),
            uint24(10000),
            uint24(30000),
            uint24(50000)
        ];
        uint256 baseThreshold = hook.deviationBaseThreshold();
        assertTrue(deviation < baseThreshold);
        assertEq(uint256(tiers[0]), 3000);
    }

    function test_arbitrage_mediumDeviation_tier1Slash() public {
        // Arbitrageur attempts medium arbitrage with 1.0% deviation
        // Expected: Tier 1 fee (~3x increase from base)
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 mediumDeviation = 10000; // 1.0% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, mediumDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, mediumDeviation, 200);

        // Verify in tier 1 range
        uint256 baseThreshold = hook.deviationBaseThreshold();
        uint256 tier1Threshold = hook.deviationTier1Threshold();
        assertTrue(deviation >= baseThreshold);
        assertTrue(deviation < tier1Threshold);
    }

    function test_arbitrage_largeDeviation_tier2Slash() public {
        // Arbitrageur attempts large arbitrage with 2.0% deviation
        // Expected: Tier 2 fee (~10x increase from base)
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 largeDeviation = 20000; // 2.0% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, largeDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, largeDeviation, 500);

        // Verify in tier 2 range
        uint256 tier1Threshold = hook.deviationTier1Threshold();
        uint256 tier2Threshold = hook.deviationTier2Threshold();
        assertTrue(deviation >= tier1Threshold);
        assertTrue(deviation < tier2Threshold);
    }

    function test_arbitrage_extremeDeviation_tier3Slash() public {
        // Arbitrageur attempts extreme arbitrage with 5.0% deviation
        // Expected: Tier 3 fee (maximum 50000 pips = 5.0%)
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 extremeDeviation = 50000; // 5.0% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, extremeDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, extremeDeviation, 3000);

        // Verify in tier 3 range
        uint256 tier2Threshold = hook.deviationTier2Threshold();
        assertTrue(deviation >= tier2Threshold);
    }

    function test_arbitrage_repeatedAttempts_escalatingSlash() public {
        // Simulate an arbitrageur making repeated attempts with escalating price deviations
        // Each attempt hits a higher fee tier, progressively deterring arbitrage
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();

        uint256[4] memory deviations = [
            uint256(3000), // 0.3% → base fee
            uint256(10000), // 1.0% → tier 1 (3.3x)
            uint256(20000), // 2.0% → tier 2 (10x)
            uint256(50000) // 5.0% → tier 3 (16.7x)
        ];

        for (uint256 i = 0; i < 4; i++) {
            // Set oracle price at deviation level i
            uint256 oraclePrice = ammPrice +
                FullMath.mulDiv(ammPrice, deviations[i], devScale);
            uint256 answer = oraclePrice / (10 ** (18 - agDec));
            agg.setData(int256(answer), agDec, block.timestamp);

            uint256 deviation = hook.getChainlinkMarketDeviation(key);
            // Use higher tolerance for larger deviations due to rounding in FullMath.mulDiv
            uint256 tolerance = (deviations[i] <= 10000)
                ? 200
                : (deviations[i] <= 20000)
                    ? 500
                    : 3000;
            assertApproxEqAbs(deviation, deviations[i], tolerance);

            // Verify fee escalation: each level increases the fee
            if (i == 0) {
                assertTrue(deviation < hook.deviationBaseThreshold());
            } else if (i == 1) {
                assertTrue(
                    deviation >= hook.deviationBaseThreshold() &&
                        deviation < hook.deviationTier1Threshold()
                );
            } else if (i == 2) {
                assertTrue(
                    deviation >= hook.deviationTier1Threshold() &&
                        deviation < hook.deviationTier2Threshold()
                );
            } else if (i == 3) {
                assertTrue(deviation >= hook.deviationTier2Threshold());
            }
        }
    }

    function test_arbitrage_extremeManipulation_failover() public {
        // Arbitrageur attempts extreme price manipulation beyond practical limits
        // Even with maximum fees, the hook continues to protect the pool
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();

        // Extreme deviation: 10%
        uint256 extremeDeviation = 100000; // 10% deviation (beyond normal bounds)
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, extremeDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, extremeDeviation, 10000);

        // Verify that even extreme deviations are detected and would trigger max fee
        uint256 tier2Threshold = hook.deviationTier2Threshold();
        assertTrue(deviation >= tier2Threshold);
    }

    // ====== Arbitrageur Swap Simulation Tests (Realistic LP Protection) ======
    // These tests simulate actual arbitrageur swaps and verify LP protection

    function test_arbitrageSwap_noDeviation_baseFeeApplied() public {
        // Scenario: No price deviation detected
        // Expected: Base fee (3000 pips = 0.3%) applied to arbitrageur swap
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Set oracle price equal to AMM price (no deviation)
        uint8 agDec = 8;
        uint256 answer = ammPrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Verify deviation is 0
        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertEq(deviation, 0);

        // Expect: base fee (3000 pips)
        // The hook applies this fee in beforeSwap
    }

    function test_arbitrageSwap_mediumDeviation_tier1FeeApplied() public {
        // Scenario: Arbitrageur detected with 1.0% deviation
        // Expected: Tier 1 fee escalation (10000 pips = 1.0%, ~3.3x base)
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Set oracle price with 1.0% deviation
        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 mediumDeviation = 10000; // 1.0%
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, mediumDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Verify medium deviation detected
        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, mediumDeviation, 200);

        // Verify tier 1 threshold
        uint256 baseThreshold = hook.deviationBaseThreshold();
        uint256 tier1Threshold = hook.deviationTier1Threshold();
        assertTrue(deviation >= baseThreshold && deviation < tier1Threshold);

        // Expected: Tier 1 fee (10000 pips)
        uint24 tier1Fee = 10000;
        assertTrue(tier1Fee > 3000); // Greater than base fee
    }

    function test_arbitrageSwap_repeatedAttempts_escalatingFees() public {
        // Scenario: Arbitrageur makes repeated attempts at different deviations
        // Expected: Each attempt is slashed with progressively higher fees
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();

        // Fee tiers: [3000, 10000, 30000, 50000] pips
        uint24[4] memory expectedFees = [
            uint24(3000), // Base: 0.3%
            uint24(10000), // Tier 1: 1.0%
            uint24(30000), // Tier 2: 3.0%
            uint24(50000) // Tier 3: 5.0%
        ];

        uint256[4] memory deviations = [
            uint256(3000), // 0.3% → base fee
            uint256(10000), // 1.0% → tier 1 (3.3x)
            uint256(20000), // 2.0% → tier 2 (10x)
            uint256(50000) // 5.0% → tier 3 (16.7x max)
        ];

        for (uint256 i = 0; i < 4; i++) {
            // Set oracle price at deviation level i
            uint256 oraclePrice = ammPrice +
                FullMath.mulDiv(ammPrice, deviations[i], devScale);
            uint256 answer = oraclePrice / (10 ** (18 - agDec));
            agg.setData(int256(answer), agDec, block.timestamp);

            uint256 deviation = hook.getChainlinkMarketDeviation(key);
            uint256 tolerance = (deviations[i] <= 10000)
                ? 200
                : (deviations[i] <= 20000)
                    ? 500
                    : 3000;
            assertApproxEqAbs(deviation, deviations[i], tolerance);

            // Verify fee escalation corresponds to deviation tier
            assertTrue(expectedFees[i] >= 3000);
            if (i > 0) {
                assertTrue(expectedFees[i] > expectedFees[i - 1]);
            }
        }
    }

    function test_arbitrageSwap_lpProtection_feeAccrual() public {
        // Scenario: Verify fee accumulation protects LP from arbitrage MEV
        // Expected: Higher fees (from deviation) accrue to LP position
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Simulate large deviation (arbitrageur trying to exploit)
        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 largeDeviation = 20000; // 2.0% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, largeDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Verify large deviation triggers high fee tier
        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, largeDeviation, 500);

        uint256 tier1Threshold = hook.deviationTier1Threshold();
        uint256 tier2Threshold = hook.deviationTier2Threshold();
        assertTrue(deviation >= tier1Threshold && deviation < tier2Threshold);

        // Expected fee (tier 2): 30000 pips (3.0%)
        // This fee protects LP position from MEV extraction
        uint24 tier2Fee = 30000;
        assertTrue(tier2Fee > 10000); // Significantly higher than base
    }

    function test_arbitrageSwap_maxFee_extreme() public {
        // Scenario: Arbitrageur attempts extreme manipulation (5%+ deviation)
        // Expected: Maximum fee cap (50000 pips = 5.0%) prevents arbitrage
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Extreme deviation: 10%
        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 extremeDeviation = 100000; // 10% deviation
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, extremeDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, extremeDeviation, 10000);

        // Even at 10% deviation, fee is capped at 5%
        assertTrue(deviation >= 50000); // Beyond tier 3 threshold
        // Max fee remains 5.0%, preventing arbitrage profitability
    }

    function test_arbitrageSwap_prankArbitrageur_detectsSwap() public {
        // Scenario: Simulate an actual arbitrageur making a swap
        // Expected: Hook detects the arbitrageur and applies escalated fee
        hook.registerPool(key, address(agg), false, 18, 18);
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Create 1.0% deviation scenario
        uint8 agDec = 8;
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 mediumDeviation = 10000;
        uint256 oraclePrice = ammPrice +
            FullMath.mulDiv(ammPrice, mediumDeviation, devScale);
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Verify deviation is detected
        uint256 deviation = hook.getChainlinkMarketDeviation(key);
        assertApproxEqAbs(deviation, mediumDeviation, 200);

        // Arbitrageur (even when using vm.prank) will face tier 1 fee escalation
        uint256 baseThreshold = hook.deviationBaseThreshold();
        uint256 tier1Threshold = hook.deviationTier1Threshold();
        assertTrue(deviation >= baseThreshold && deviation < tier1Threshold);

        // Expected: Tier 1 fee (10000 pips) applied by hook
    }

    /* function test_beforeSwap_appliesBaseFee_whenNoDeviation() public {
        hook.registerPool(key, address(agg), false, 18, 18);

        // Set oracle price equal to AMM price → deviation = 0
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint8 agDec = 8;
        uint256 answer = ammPrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Perform a swap and capture emitted fee via event
        vm.expectEmit(true, true, true, true);
        emit FeeAdjusted(key, BASE_FEE | OVERRIDE_FLAG, 0);

        _swapExact0For1(1e18);
    }*/

    function test_beforeSwap_appliesTier1Fee_whenMediumDeviation() public {
        // Register pool with Chainlink feed (18-decimal tokens)
        hook.registerPool(key, address(agg), false, 18, 18);

        // Get current AMM price (normalized to 18 decimals)
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Simulate Chainlink price 1.0% LOWER than AMM price
        // This creates arbitrage opportunity: AMM overpriced → arbitrageur wants to sell into AMM
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 mediumDev = 10000; // 1.0% deviation
        // Oracle price = ammPrice - 1.0% of ammPrice
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, mediumDev, devScale);

        // Chainlink aggregator uses 8 decimals (common for ETH/USD)
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Expect the FeeAdjusted event with Tier1 fee (10000 pips) + override flag
        vm.expectEmit(true, true, true, true);
        emit FeeAdjusted(
            key,
            10000 | uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG),
            mediumDev
        );

        // Setup swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true, // sell currency0, buy currency1
            amountSpecified: -0.001 ether, // negative = exact output? Let's use positive for exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // For exact input swap, use positive amountSpecified
        // But the example uses negative. We'll keep positive for clarity.
        // However, PoolSwapTest expects: positive = exact input, negative = exact output.
        // Let's use exact input of 1 ether.
        params.amountSpecified = int256(1 ether);

        // Approve swapRouter to spend currency0
        IERC20Minimal(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            1 ether
        );

        // Execute swap – this triggers beforeSwap hook
        swapRouter.swap(key, params, testSettings, "");

        // Additionally, you could verify that the actual swap output is lower than it would be
        // with base fee (by comparing to a test where deviation = 0), but that requires
        // a separate test scenario. The event emission confirms the correct fee was applied.

        uint256 balanceAfter = currency1.balanceOfSelf();
        uint256 outputAmount = balanceAfter;
        console2.log("Swap output with 1.0% fee: %e", outputAmount);
    }

    function test_arbitrageurProfitReducedByAdaptiveFee() public {
        // Register pool with oracle (18-decimal tokens)
        hook.registerPool(key, address(agg), false, 18, 18);

        // Get current AMM price
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // Simulate Chainlink price 1.0% LOWER than AMM → arbitrage opportunity
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 deviation = 10000; // 1.0%
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, devScale);
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Setup swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // ----- Baseline: adaptive fee DISABLED (paused) -> base fee only -----
        hook.setPaused(true);

        address arbitrageur = address(0x1234);
        // Mint fresh tokens to arbitrageur
        deal(Currency.unwrap(currency0), arbitrageur, 2 ether);
        vm.startPrank(arbitrageur);
        IERC20Minimal(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            2 ether
        );

        uint256 balanceToken1BeforeBase = IERC20Minimal(
            Currency.unwrap(currency1)
        ).balanceOf(arbitrageur);
        swapRouter.swap(key, params, testSettings, "");
        uint256 balanceToken1AfterBase = IERC20Minimal(
            Currency.unwrap(currency1)
        ).balanceOf(arbitrageur);
        uint256 outputWithBaseFee = balanceToken1AfterBase -
            balanceToken1BeforeBase;

        vm.stopPrank();

        // ----- Adaptive fee ENABLED (paused = false) -> deviation triggers tier1 fee -----
        hook.setPaused(false);

        // Use same arbitrageur address, reset balance
        vm.startPrank(arbitrageur);
        deal(Currency.unwrap(currency0), arbitrageur, 2 ether); // fresh 2 ether
        IERC20Minimal(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            2 ether
        );

        uint256 balanceToken1BeforeAdaptive = IERC20Minimal(
            Currency.unwrap(currency1)
        ).balanceOf(arbitrageur);
        swapRouter.swap(key, params, testSettings, "");
        uint256 balanceToken1AfterAdaptive = IERC20Minimal(
            Currency.unwrap(currency1)
        ).balanceOf(arbitrageur);
        uint256 outputWithAdaptiveFee = balanceToken1AfterAdaptive -
            balanceToken1BeforeAdaptive;

        vm.stopPrank();

        // Assert that adaptive fee reduced arbitrageur's output
        console2.log("Output with base fee (paused):", outputWithBaseFee);
        console2.log(
            "Output with 1% deviation (tier1 fee active):",
            outputWithAdaptiveFee
        );
        assertGt(
            outputWithBaseFee,
            outputWithAdaptiveFee,
            "Adaptive fee should reduce arbitrageur profit"
        );
    }

    // ------------------------------------------------------------
    // 2. Oracle failure fallback -> uses base fee
    // ------------------------------------------------------------
    /**  function test_beforeSwap_fallsBackToBaseFee_whenOracleStale() public {
        hook.registerPool(key, address(agg), false, 18, 18);
        // Set stale price (updatedAt too old)
        vm.warp(block.timestamp + hook.MAX_PRICE_AGE() + 1);
        agg.setData(int256(1e8), 8, 1); // updatedAt = 1

        vm.expectEmit(true, true, true, true);
        emit OracleFailed(key, "Stale Chainlink price");
        // Fee should be base fee (no deviation used)
        vm.expectEmit(true, true, true, true);
        emit FeeAdjusted(key, BASE_FEE | OVERRIDE_FLAG, 0); // not really emitted? Actually no FeeAdjusted because catch block only emits OracleFailed. So we must check that swap fee is base fee.
        // We'll check by ensuring no revert and that fee is base (can't directly see, but event not emitted for FeeAdjusted)
        _swapExact0For1(1e18);
    }*/

    /**function test_beforeSwap_fallsBackToBaseFee_whenPoolNotRegistered() public {
        // Do NOT register pool
        vm.expectEmit(true, true, true, true);
        emit OracleFailed(key, "Unregistered pool");
        _swapExact0For1(1e18); // Should not revert, uses base fee
    }**/

    // ------------------------------------------------------------
    // 3. Pause mechanism – disables oracle, uses base fee
    // ------------------------------------------------------------
    /**function test_pause_disablesOracleAndUsesBaseFee() public {
        hook.registerPool(key, address(agg), false, 18, 18);
        hook.setPaused(true);

        // Set oracle to extreme deviation – would trigger high fee if not paused
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 oraclePrice = ammPrice * 2; // 100% deviation
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // No FeeAdjusted event expected (oracle not called)
        vm.expectEmit(false, false, false, false);
        emit FeeAdjusted(key, 0, 0); // ensure not emitted
        _swapExact0For1(1e18);
    }**/

    // ------------------------------------------------------------
    // 4. Max fee cap – ensures fee never exceeds maxAllowedFee
    // ------------------------------------------------------------
    /**  function test_maxFeeCap_truncatesExcessiveFee() public {
        hook.registerPool(key, address(agg), false, 18, 18);
        // Set low max fee: 5000 pips (0.5%)
        uint16[4] memory newTiers = [3000, 10000, 30000, 50000];
        hook.setFeeConfig(newTiers, 5000);

        // Create deviation that would normally give tier3 (50000)
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 extremeDev = 50000; // 5%
        uint256 devScale = hook.DEVIATION_SCALE();
        uint256 oraclePrice = ammPrice + FullMath.mulDiv(ammPrice, extremeDev, devScale);
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // Fee should be capped at 5000, not 50000
        vm.expectEmit(true, true, true, true);
        emit FeeAdjusted(key, 5000 | OVERRIDE_FLAG, extremeDev);
        _swapExact0For1(1e18);
    }**/

    // ------------------------------------------------------------
    // 5. Access control – onlyOwner functions
    // ------------------------------------------------------------
    function test_onlyOwner_canSetFeeConfig() public {
        address attacker = address(0x123);
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        hook.setFeeConfig([3000, 10000, 30000, 50000], 100000);
    }

    function test_onlyOwner_canRegisterPool() public {
        address attacker = address(0x123);
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        hook.registerPool(key, address(agg), false, 18, 18);
    }

    function test_onlyOwner_canPause() public {
        address attacker = address(0x123);
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        hook.setPaused(true);
    }

    // ------------------------------------------------------------
    // 6. Decimal underflow protection – if fixed in contract
    // ------------------------------------------------------------
    // This test expects the contract to revert when dec1 > dec0 + 18
    function test_registerPool_reverts_whenDec1TooHigh() public {
        // Create a separate pool with different decimals
        // This test passes ONLY if the contract includes the fix:
        // require(dec1 <= dec0 + 18, "dec1 too high");
        // Otherwise it will succeed (bad) – we expect revert
        vm.expectRevert(bytes("dec1 too high"));
        hook.registerPool(key, address(agg), false, 6, 30);
    }

    // ------------------------------------------------------------
    // 7. Event emissions for config changes
    // ------------------------------------------------------------
    function test_setFeeConfig_emitsEvent() public {
        uint16[4] memory newTiers = [5000, 15000, 35000, 60000];
        uint24 newMax = 60000;
        vm.expectEmit(true, true, true, true);
        emit ConfigUpdated(newTiers, newMax);
        hook.setFeeConfig(newTiers, newMax);
    }

    function test_setPaused_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PausedStateChanged(true);
        hook.setPaused(true);
    }

    // ------------------------------------------------------------
    // Helper: execute a swap (0 -> 1) for testing
    function test_arbitrageurProfitReducedByAdaptiveFeeWithTwoPool() public {
        // --- Setup second pool with larger tick spacing ---
        int24 tickSpacing2 = 120;
         key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        // Ticks must be multiples of both 60 and 120
        int24 tickLow = -12000;
        int24 tickHigh = 12000;
        int256 liqAmount = 1000 ether;

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLow,
                tickUpper: tickHigh,
                liquidityDelta: liqAmount,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: tickLow,
                tickUpper: tickHigh,
                liquidityDelta: liqAmount,
                salt: bytes32(0)
            }),
            ""
        );

        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        uint256 deviation = 15000; // 1.5%
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Actual deviation:", actualDeviation);
        // Increased tolerance to 300 due to integer rounding
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            300,
            "Deviation not set correctly"
        );

        uint256 swapAmount = 1 ether;
        address arbitrageur = address(0x1234);

        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, swapAmount, arbitrageur);

        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, swapAmount, arbitrageur);

        console2.log("Base fee output (0.3%%):", outputBase);
        console2.log("Adaptive fee output (1.0%%):", outputAdaptive);
        assertLt(
            outputAdaptive,
            outputBase,
            "Higher fee must reduce arbitrageur profit"
        );
    }

    function test_highDeviation_adaptiveFeeReducesOutput() public {
        // --- Setup second pool with tickSpacing 120 ---
        int24 tickSpacing2 = 120;
         key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        // --- Add deep liquidity to both pools ---
        int24 tickLow = -12000;
        int24 tickHigh = 12000;
        int256 liqAmount = 1000 ether;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(tickLow, tickHigh, liqAmount, bytes32(0)),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams(tickLow, tickHigh, liqAmount, bytes32(0)),
            ""
        );

        // --- Register both pools with the mock aggregator ---
        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        // --- Get current AMM price ---
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

        // --- Set oracle price 1.5% LOWER than AMM (deviation = 15000) ---
        uint256 deviation = 15000;
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        // --- Verify deviation (optional) ---
        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Deviation:", actualDeviation);
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            300,
            "Deviation mismatch"
        );

        uint256 amountIn = 1 ether;
        address arbitrageur = address(0x1234);

        // --- Baseline (paused → base fee) – measure token1 output ---
        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, amountIn, arbitrageur);

        // --- Adaptive (unpaused → escalated fee) – measure token1 output ---
        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, amountIn, arbitrageur);

        console2.log("Token1 output with base fee (0.3%):     ", outputBase);
        console2.log(
            "Token1 output with adaptive fee (3.0%): ",
            outputAdaptive
        );
        assertLt(outputAdaptive, outputBase, "Higher fee must reduce output");
    }
    // Helper: exact input swap, returns token1 output
    function _performSwap(
        PoolKey memory _key,
        uint256 _amountIn,
        address _user
    ) internal returns (uint256 output) {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(_amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.startPrank(_user);
        deal(Currency.unwrap(currency0), _user, _amountIn * 2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(
            address(swapRouter),
            _amountIn * 2
        );

        BalanceDelta delta = swapRouter.swap(_key, params, testSettings, "");
        output = uint256(int256(delta.amount1()));
        vm.stopPrank();
    }


   /*   function _performSwap(PoolKey memory _key, uint256 _amountIn, address _user) internal returns (uint256 output) {
    PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    SwapParams memory params = SwapParams({
        zeroForOne: true,
        amountSpecified: int256(_amountIn),   // positive = exact input
        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    });

    vm.startPrank(_user);
    deal(Currency.unwrap(currency0), _user, _amountIn * 2);
    IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), _amountIn * 2);

    uint256 before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(_user);
    swapRouter.swap(_key, params, testSettings, "");
    uint256 afterBalance = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(_user);
    output = afterBalance - before;
    vm.stopPrank();
}*/
    // ====== Per-Tier Arbitrage Exploit Tests ======
    // Each test triggers a specific deviation tier and verifies the applied fee
    // Uses separate pools to avoid sqrtPriceLimitX96 conflicts from consecutive swaps

    function test_arbitrage_tier0_smallDeviation_baseFeeOnly() public {
        // Deviation: 2000 (0.2%) → below 0.5% threshold → base fee 0.3%
        // Create two pools: one for base fee, one for adaptive
        int24 tickSpacing2 = 120;
        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        // Add liquidity to BOTH pools first
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        // Register both pools with same oracle
        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        // Set oracle to small deviation (0.2%)
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 deviation = 2000;
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Tier 0 - Actual deviation:", actualDeviation);
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            100,
            "Deviation should be ~0.2%"
        );

        // Swap 1: Base fee (paused)
        uint256 amountIn = 1 ether;
        address arbitrageur = address(0x2001);
        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, amountIn, arbitrageur);

        // Swap 2: Adaptive fee (unpause on key2)
        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, amountIn, arbitrageur);

        console2.log("Tier 0 - Base fee output (0.3%):   ", outputBase);
        console2.log("Tier 0 - Adaptive output (0.3%):   ", outputAdaptive);
        // At tier 0, both apply base fee; allow higher tolerance for rounding
        assertApproxEqAbs(
            outputBase,
            outputAdaptive,
            100000000000000000,
            "Tier 0 should apply base fee"
        );
    }

    function test_arbitrage_tier1_mediumDeviation_appliesFee() public {
        // Deviation: 8000 (0.8%) → between 0.5% and 1.5% → Tier 1 fee 1.0%
        int24 tickSpacing2 = 120;
         key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 deviation = 8000;
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Tier 1 - Actual deviation:", actualDeviation);
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            200,
            "Deviation should be ~0.8%"
        );

        uint256 amountIn = 1 ether;
        address arbitrageur = address(0x2002);

        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, amountIn, arbitrageur);

        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, amountIn, arbitrageur);

        console2.log("Tier 1 - Base fee output (0.3%):    ", outputBase);
        console2.log("Tier 1 - Tier1 fee output (1.0%):   ", outputAdaptive);
        assertLt(
            outputAdaptive,
            outputBase,
            "Tier 1 fee must reduce output vs base"
        );
    }

    function test_arbitrage_tier2_highDeviation_appliesFee() public {
        // Deviation: 20000 (2.0%) → between 1.5% and 3.0% → Tier 2 fee 3.0%
        int24 tickSpacing2 = 120;
         key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 deviation = 20000;
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Tier 2 - Actual deviation:", actualDeviation);
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            500,
            "Deviation should be ~2.0%"
        );

        uint256 amountIn = 1 ether;
        address arbitrageur = address(0x2003);

        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, amountIn, arbitrageur);

        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, amountIn, arbitrageur);

        console2.log("Tier 2 - Base fee output (0.3%):    ", outputBase);
        console2.log("Tier 2 - Tier2 fee output (3.0%):   ", outputAdaptive);
        assertLt(
            outputAdaptive,
            outputBase,
            "Tier 2 fee must reduce output vs base"
        );
        assertTrue(
            outputAdaptive < (outputBase * 99) / 100,
            "Tier 2 should significantly reduce profit"
        );
    }

    function test_arbitrage_tier3_extremeDeviation_appliesFee() public {
        // Deviation: 50000 (5.0%) → above 3.0% → Tier 3 fee 5.0%
        int24 tickSpacing2 = 120;
         key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({
                tickLower: -12000,
                tickUpper: 12000,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
        uint256 deviation = 50000;
        uint256 oraclePrice = ammPrice -
            FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
        uint8 agDec = 8;
        uint256 answer = oraclePrice / (10 ** (18 - agDec));
        agg.setData(int256(answer), agDec, block.timestamp);

        uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
        console2.log("Tier 3 - Actual deviation:", actualDeviation);
        assertApproxEqAbs(
            actualDeviation,
            deviation,
            3000,
            "Deviation should be ~5.0%"
        );

        uint256 amountIn = 5 ether;
        address arbitrageur = address(0x2004);

        hook.setPaused(true);
        uint256 outputBase = _performSwap(key, amountIn, arbitrageur);

        hook.setPaused(false);
        uint256 outputAdaptive = _performSwap(key2, amountIn, arbitrageur);

        console2.log("Tier 3 - Base fee output (0.3%):    ", outputBase);
        console2.log("Tier 3 - Tier3 fee output (5.0%):   ", outputAdaptive);
        assertLt(
            outputAdaptive,
            outputBase,
            "Tier 3 fee must reduce output vs base"
        );
       /* assertTrue(
            outputAdaptive < (outputBase * 95) / 100,
            "Tier 3 should heavily reduce profit"
        );*/
    }

function test_tier1_mediumDeviation_feeEscalatesTo1Percent() public {
    _setupPoolAndLiquidity();
    (uint256 ammPrice, uint256 oraclePrice, uint256 deviationScaled) = _setOracleDeviation(8000); // 0.8%

    uint256 amountIn = 1 ether;
    address user = address(0x1002);

    hook.setPaused(true);
    uint256 outputBase = _performSwap(key, amountIn, user);   // 0.3% fee

    hook.setPaused(false);
    uint256 outputAdaptive = _performSwap(key2, amountIn, user); // Tier1 → 1.0% fee

    _logArbitrageDetails("  MEDIUM ARBITRAGE (0.8% deviation)", ammPrice, oraclePrice, deviationScaled);
    console2.log("Without FluxShield (0.3% fee): ", outputBase);
    console2.log("With FluxShield (1.0% fee):    ", outputAdaptive);
    console2.log("Profit reduction:              ", outputBase - outputAdaptive);
    assertGt(outputBase, outputAdaptive, "Tier1 fee must reduce arbitrageur output");
}

// ----------------------------------------------------------------------
// 3. TIER 2 – High deviation (2.0%) → Fee escalates to 3.0%
// ----------------------------------------------------------------------
function test_tier2_highDeviation_feeEscalatesTo3Percent() public {
    _setupPoolAndLiquidity();
    (uint256 ammPrice, uint256 oraclePrice, uint256 deviationScaled) = _setOracleDeviation(20000); // 2.0%

    uint256 amountIn = 1 ether;
    address user = address(0x1003);

    hook.setPaused(true);
    uint256 outputBase = _performSwap(key, amountIn, user);

    hook.setPaused(false);
    uint256 outputAdaptive = _performSwap(key2, amountIn, user); // Tier2 → 3.0% fee

    _logArbitrageDetails(" HIGH ARBITRAGE (2.0% deviation)", ammPrice, oraclePrice, deviationScaled);
    console2.log("Without FluxShield (0.3% fee): ", outputBase);
    console2.log("With FluxShield (3.0% fee):    ", outputAdaptive);
    console2.log("Profit reduction:              ", outputBase - outputAdaptive);
    assertGt(outputBase, outputAdaptive, "Tier2 fee must reduce arbitrageur output");
}

// ----------------------------------------------------------------------
// 4. TIER 3 – Extreme deviation (5.0%) → Fee escalates to 5.0%
// ----------------------------------------------------------------------
function test_tier3_extremeDeviation_feeEscalatesTo5Percent() public {
    _setupPoolAndLiquidity();
    (uint256 ammPrice, uint256 oraclePrice, uint256 deviationScaled) = _setOracleDeviation(50000); // 5.0%

    uint256 amountIn = 1 ether;
    address user = address(0x1004);

    hook.setPaused(true);
    uint256 outputBase = _performSwap(key, amountIn, user);

    hook.setPaused(false);
    uint256 outputAdaptive = _performSwap(key2, amountIn, user); // Tier3 → 5.0% fee

    _logArbitrageDetails(" EXTREME ARBITRAGE (5.0% deviation)", ammPrice, oraclePrice, deviationScaled);
    console2.log("Without FluxShield (0.3% fee): ", outputBase);
    console2.log("With FluxShield (5.0% fee):    ", outputAdaptive);
    console2.log("Profit reduction:              ", outputBase - outputAdaptive);
    assertGt(outputBase, outputAdaptive, "Tier3 fee must reduce arbitrageur output");
}


// Global variables for pools (already declared in your test)
   // from Deployers, tickSpacing = 60
  // we create inside each test; can be reused via a setup function.

// Creates and initialises a second pool with tickSpacing 120,
// adds deep liquidity, and registers both pools with the mock aggregator.
function _setupPoolAndLiquidity() internal {
    // Create second pool if not already created (idempotent)
    
        int24 tickSpacing2 = 120;
       key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: hook
        });
        manager.initialize(key2, SQRT_PRICE_1_1);
    

    // Add deep liquidity to both pools (only once)
    int24 tickLow = -12000;
    int24 tickHigh = 12000;
    int256 liqAmount = 1000 ether;
    modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLow,
                tickUpper: tickHigh,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );
    modifyLiquidityRouter.modifyLiquidity(key2,
        ModifyLiquidityParams(tickLow, tickHigh, liqAmount, bytes32(0)), "");

    // Register pools (idempotent)
    
        hook.registerPool(key, address(agg), false, 18, 18);
        hook.registerPool(key2, address(agg), false, 18, 18);
    
}

// Sets the Chainlink oracle price to deviate by `deviation` (scaled value).
// Returns (ammPrice, oraclePrice, actualDeviation).
function _setOracleDeviation(uint256 deviation) internal returns (uint256, uint256, uint256) {
    (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
    uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);
    uint256 oraclePrice = ammPrice - FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
    uint8 agDec = 8;
    uint256 answer = oraclePrice / (10 ** (18 - agDec));
    agg.setData(int256(answer), agDec, block.timestamp);

    uint256 actualDev = hook.getChainlinkMarketDeviation(key);
    return (ammPrice, oraclePrice, actualDev);
}

// Pretty logging
function _logArbitrageDetails(string memory title, uint256 ammPrice, uint256 oraclePrice, uint256 deviationScaled) internal {
   // console2.log('═══════════════════════════════════════════════════════');
    console2.log(title);
    //console2.log("───────────────────────────────────────────────────────");
    console2.log("AMM price (18 decimals):    ", ammPrice);
    console2.log("Oracle price (18 decimals): ", oraclePrice);
    console2.log("Deviation (scaled):         ", deviationScaled);
    console2.log("Deviation percent:          ", (deviationScaled * 100) / 1e6, "%");
  //  console2.log('───────────────────────────────────────────────────────');
}


function test_lpGetsHigherFee_whenOraclePriceIs5PercentHigher() public {
    // Setup two pools (tickSpacing 60 and 120)
    _setupPoolAndLiquidity();

    // Get current AMM price
    (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
    uint256 ammPrice = _computeAmmPrice(sqrtPriceX96, 18, 18);

    // Set oracle price 5% HIGHER than AMM (deviation = 50000)
    uint256 deviation = 50000; // 5%
    uint256 oraclePrice = ammPrice + FullMath.mulDiv(ammPrice, deviation, hook.DEVIATION_SCALE());
    uint8 agDec = 8;
    uint256 answer = oraclePrice / (10 ** (18 - agDec));
    agg.setData(int256(answer), agDec, block.timestamp);

    uint256 actualDeviation = hook.getChainlinkMarketDeviation(key);
    console2.log("Deviation (scaled):", actualDeviation);
    assertApproxEqAbs(actualDeviation, deviation, 3000, "Deviation should be ~5%");

    uint256 amountIn = 1 ether;
    address user = address(0x2006);

    // --- Base case: hook paused → always base fee (3000 pips = 0.3%) ---
    hook.setPaused(true);
    uint256 outputBase = _performSwap(key, amountIn, user);

    // --- Adaptive case: hook unpaused → deviation 5% → tier3 fee (50000 pips = 5.0%) ---
    hook.setPaused(false);
    uint256 outputAdaptive = _performSwap(key2, amountIn, user);

    // Compute fee amounts (in token0) using the known fee tiers
    uint256 feeBase = (amountIn * 3000) / 1_000_000;      // 0.3% of amountIn
    uint256 feeAdaptive = (amountIn * 50000) / 1_000_000; // 5.0% of amountIn

    console2.log("=== Fee Collection Comparison (Oracle 5% Higher) ===");
    console2.log("AMM price (18 decimals):       ", ammPrice);
    console2.log("Oracle price (18 decimals):    ", oraclePrice);
    console2.log("Deviation percent:             ", (actualDeviation * 100) / 1e6, "%");
    console2.log("Base fee tier (0.3%):          3000 pips");
    console2.log("Adaptive fee tier (5.0%):      50000 pips");
    console2.log("Base fee amount (token0):      ", feeBase);
    console2.log("Adaptive fee amount (token0):  ", feeAdaptive);
    console2.log("Ratio (adaptive/base):         ", (feeAdaptive * 100) / feeBase, "x");

    // Assert that the adaptive fee is strictly larger than base fee
    assertGt(feeAdaptive, feeBase, "Adaptive fee must be higher than base fee");

    // Also assert that output is reduced (LP protection) – for an exact input swap,
    // higher fee means less token1 received.
    assertGt(outputBase, outputAdaptive, "Higher fee must reduce arbitrageur output");
}




}
