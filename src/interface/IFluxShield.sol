// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

interface IFluxShield is IHooks {
    struct PoolConfig {
        uint8 dec0;
        uint8 dec1;
        bytes32 priceFeedId;
        bool isInverse;
    }

    // =============================================================
    //                          EVENTS
    // =============================================================

    /// @notice Emitted when adaptive fee is updated during swap
    event FeeAdjusted(
        PoolKey indexed key,
        uint24 fee,
        uint256 deviation,
        uint256 confidence
    );

    /// @notice Emitted when global fee config is updated
    event FeeConfigUpdated(
        uint24[4] tiers,
        uint24 maxAllowedFee,
        uint32 confThreshold
    );

    /// @notice Emitted when hook is paused/unpaused
    event PausedStateChanged(bool paused);

    /// @notice Emitted when oracle call fails safely
    event OracleFailed(PoolKey indexed key);

    /// @notice Emitted when pool is registered
    event PoolRegistered(
        PoolKey indexed key,
        bytes32 priceFeedId,
        bool isInverse
    );

    // =============================================================
    //                      HOOK CONFIGURATION
    // =============================================================

    /// @notice Returns hook permission bitmap for BaseHook
    function getHookPermissions()
        external
        pure
        returns (Hooks.Permissions memory);

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns oracle vs AMM deviation + confidence ratio
    function getMarketState(
        PoolKey calldata key
    ) external view returns (uint256 deviation, uint256 confidence);

    /// @notice Returns fee tier at index
    function feeTiers(uint256 index) external view returns (uint24);

    /// @notice Returns max allowed fee
    function maxAllowedFee() external view returns (uint24);

    /// @notice Returns oracle confidence threshold
    function confThreshold() external view returns (uint32);

    /// @notice Returns pool manager
    function MANAGER() external view returns (IPoolManager);

    /// @notice Returns Pyth oracle

    /// @notice Returns max oracle age
    function MAX_ORACLE_AGE() external view returns (uint256);

    /// @notice Returns pool configuration
    function poolConfigs(
        PoolId id
    )
        external
        view
        returns (uint8 dec0, uint8 dec1, bytes32 priceFeedId, bool isInverse);

    /// @notice Returns pause state
    function paused() external view returns (bool);

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    /// @notice Sets fee tiers and safety constraints
    function setFeeConfig(
        uint24[4] calldata tiers,
        uint24 maxAllowedFee,
        uint32 confThreshold
    ) external;

    /// @notice Registers a pool with oracle mapping
    function registerPool(
        PoolKey calldata key,
        PoolConfig calldata config
    ) external;

    /// @notice Toggles pause state
    function setPaused(bool paused) external;
}
