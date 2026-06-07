// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    StateLibrary
} from "v4-hooks-public/lib/v4-core/src/libraries/StateLibrary.sol";
import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Minimal ERC20 interface to fetch decimals
interface IERC20Minimal {
    function decimals() external view returns (uint8);
}

/**
 * @title FluxShield
 * @notice An oracle-aware adaptive fee hook for Uniswap v4 that mitigates LVR by
 *         scaling swap fees based on real-time price deviation between the AMM and
 *         a Chainlink price feed.
 *
 * @dev Inherits from BaseHook to reduce boilerplate. Only the `beforeSwap` hook is used.
 *      The contract must be deployed at an address with the `beforeSwap` hook flag set.
 *
 * @custom:security Features:
 *          - Staleness check: reverts if the Chainlink price is older than MAX_PRICE_AGE.
 *          - Maximum fee sanity bound.
 *          - Pause mechanism (owner can disable adaptive logic).
 *          - Pool registration with decimal validation.
 */
contract FluxShieldHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    // --- Constants ------------------------------------------------------------
    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEVIATION_SCALE = 1e6; // 100% = 1,000,000
    uint256 public constant MAX_PRICE_AGE = 2 hours; // Maximum age for Chainlink price

    // --- Configurable Storage ------------------------------------------------
    uint16[4] public feeTiers; // [Base, Tier1, Tier2, Tier3]
    uint24 public maxAllowedFee; // Sanity bound (e.g. 10% = 100000)
    bool public paused; // Global circuit breaker

    // Deviation thresholds (scaled by DEVIATION_SCALE)
    uint256 public deviationBaseThreshold;
    uint256 public deviationTier1Threshold;
    uint256 public deviationTier2Threshold;

    // --- Pool Configuration --------------------------------------------------
    struct PoolConfig {
        AggregatorV3Interface chainlinkFeed;
        bool inversePrice; // Whether to invert the price (1 / price)
        uint8 dec0;
        uint8 dec1;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;

    // --- Events --------------------------------------------------------------
    event ConfigUpdated(uint16[4] tiers, uint24 maxFee);
    event DeviationThresholdsUpdated(
        uint256 base,
        uint256 tier1,
        uint256 tier2
    );
    event PoolRegistered(PoolKey indexed key, address feed, bool inverse);
    event PoolUnregistered(PoolId indexed poolId);
    event PausedStateChanged(bool isPaused);
    event FeeAdjusted(PoolKey indexed key, uint24 fee, uint256 deviation);
    event OracleFailed(PoolKey indexed key, string reason);

    // --- Constructor ---------------------------------------------------------
    constructor(IPoolManager _manager) BaseHook(_manager) Ownable(msg.sender) {
        // Default fee tiers (in pips: 1 pip = 0.0001%)
        feeTiers = [3000, 10000, 30000, 50000]; // 0.3%, 1.0%, 3.0%, 5.0%
        maxAllowedFee = 100000; // 10% absolute maximum

        // Default deviation thresholds
        deviationBaseThreshold = 5000; // 0.5%
        deviationTier1Threshold = 15000; // 1.5%
        deviationTier2Threshold = 30000; // 3.0%

        // Validate hook address flags
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // --- Hook Permissions ----------------------------------------------------
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
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
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

    // --- Configuration Functions (onlyOwner) ---------------------------------
    function setFeeConfig(
        uint16[4] memory _tiers,
        uint24 _maxAllowedFee
    ) external onlyOwner {
        for (uint256 i = 0; i < _tiers.length; i++) {
            require(_tiers[i] <= _maxAllowedFee, "Fee tier exceeds max");
        }
        feeTiers = _tiers;
        maxAllowedFee = _maxAllowedFee;
        emit ConfigUpdated(_tiers, _maxAllowedFee);
    }

    function setDeviationThresholds(
        uint256 base,
        uint256 tier1,
        uint256 tier2
    ) external onlyOwner {
        require(
            base < tier1 && tier1 < tier2 && tier2 <= DEVIATION_SCALE,
            "Invalid thresholds"
        );
        deviationBaseThreshold = base;
        deviationTier1Threshold = tier1;
        deviationTier2Threshold = tier2;
        emit DeviationThresholdsUpdated(base, tier1, tier2);
    }

    /**
     * @notice Registers a pool with its Chainlink price feed and decimal configuration.
     * @param key      The PoolKey.
     * @param feed     The Chainlink price feed address.
     * @param inverse  If true, inverts the price (1 / price) to match pool ordering.
     * @param dec0     Decimals of currency0.
     * @param dec1     Decimals of currency1.
     */
    function registerPool(
        PoolKey calldata key,
        address feed,
        bool inverse,
        uint8 dec0,
        uint8 dec1
    ) external onlyOwner {
        // Validate decimals
        if (!key.currency0.isAddressZero()) {
            require(
                IERC20Minimal(Currency.unwrap(key.currency0)).decimals() ==
                    dec0,
                "dec0 mismatch"
            );
        } else {
            require(dec0 == 18, "Native ETH must have 18 decimals");
        }
        if (!key.currency1.isAddressZero()) {
            require(
                IERC20Minimal(Currency.unwrap(key.currency1)).decimals() ==
                    dec1,
                "dec1 mismatch"
            );
        } else {
            require(dec1 == 18, "Native ETH must have 18 decimals");
        }

        require(dec1 <= dec0 + 18, "dec1 too high");

        poolConfigs[key.toId()] = PoolConfig({
            chainlinkFeed: AggregatorV3Interface(feed),
            inversePrice: inverse,
            dec0: dec0,
            dec1: dec1
        });
        emit PoolRegistered(key, feed, inverse);
    }

    function unregisterPool(PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();
        delete poolConfigs[id];
        emit PoolUnregistered(id);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    // --- BaseHook Overrides -------------------------------------------------
    /**
     * @notice beforeSwap hook that applies an adaptive fee based on Chainlink price deviation.
     * @dev If the hook is paused or the oracle fails, falls back to the base fee.
     * @return selector The function selector.
     * @return delta The before swap delta (always zero for fee override).
     * @return fee The fee (with OVERRIDE_FEE_FLAG set).
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = feeTiers[0]; // default base fee

        if (!paused) {
            try this.getChainlinkMarketDeviation(key) returns (
                uint256 deviation
            ) {
                fee = _computeAdaptiveFee(deviation);
                emit FeeAdjusted(key, fee, deviation);
            } catch (bytes memory reason) {
                emit OracleFailed(key, string(reason));
            }
        }

        if (fee > maxAllowedFee) fee = maxAllowedFee;

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /**
     * @notice Fetches the current market deviation between the AMM and Chainlink.
     * @dev External so that `beforeSwap` can call it inside a `try-catch` block.
     *      Reverts if the pool is not registered or the Chainlink price is stale.
     * @param key The pool key.
     * @return deviation Scaled absolute price deviation (DEVIATION_SCALE = 100%).
     */
    function getChainlinkMarketDeviation(
        PoolKey calldata key
    ) external view returns (uint256 deviation) {
        PoolConfig storage config = poolConfigs[key.toId()];
        require(
            address(config.chainlinkFeed) != address(0),
            "Unregistered pool"
        );

        // 1. Get Chainlink price with staleness check
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = config.chainlinkFeed.latestRoundData();
        require(answer > 0, "Invalid Chainlink price");
        require(
            updatedAt + MAX_PRICE_AGE >= block.timestamp,
            "Stale Chainlink price"
        );

        // 2. Normalize Chainlink price to 18 decimals
        uint8 chainlinkDecimals = config.chainlinkFeed.decimals();
        uint256 oraclePrice = _normalizeChainlinkPrice(
            uint256(answer),
            chainlinkDecimals,
            config.inversePrice
        );

        // 3. Get AMM price from pool state
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint256 ammPrice = _getAmmPrice(sqrtPriceX96, config.dec0, config.dec1);

        // 4. Compute absolute deviation
        uint256 diff = oraclePrice > ammPrice
            ? oraclePrice - ammPrice
            : ammPrice - oraclePrice;
        deviation = FullMath.mulDiv(diff, DEVIATION_SCALE, oraclePrice);
    }

    // --- Internal Helper Functions ------------------------------------------
    function _normalizeChainlinkPrice(
        uint256 price,
        uint8 chainlinkDecimals,
        bool inverse
    ) internal pure returns (uint256) {
        uint256 normalized;
        if (chainlinkDecimals <= 18) {
            normalized = price * (10 ** (18 - chainlinkDecimals));
        } else {
            normalized = price / (10 ** (chainlinkDecimals - 18));
        }

        if (inverse) {
            return (PRECISION * PRECISION) / normalized;
        }
        return normalized;
    }

    function _getAmmPrice(
        uint160 sqrtPriceX96,
        uint8 dec0,
        uint8 dec1
    ) internal pure returns (uint256) {
        // Price = (sqrtPriceX96 / 2^96)^2 * 10^(dec0 - dec1) * 1e18
        uint256 exponent = 18 + uint256(dec0);
        uint256 step1 = FullMath.mulDiv(
            sqrtPriceX96,
            10 ** (exponent - uint256(dec1)),
            1 << 96
        );
        return FullMath.mulDiv(sqrtPriceX96, step1, 1 << 96);
    }

    function _computeAdaptiveFee(
        uint256 deviation
    ) internal view returns (uint24) {
        if (deviation < deviationBaseThreshold) {
            return feeTiers[0];
        } else if (deviation < deviationTier1Threshold) {
            return feeTiers[1];
        } else if (deviation < deviationTier2Threshold) {
            return feeTiers[2];
        } else {
            return feeTiers[3];
        }
    }
}
