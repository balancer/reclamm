// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IReClammPoolExtension } from "./IReClammPoolExtension.sol";
import { IReClammPoolMain } from "./IReClammPoolMain.sol";

/**
 * @notice Struct with data for deploying a new ReClammPool.
 * @param name The name of the pool
 * @param symbol The symbol of the pool
 * @param version The pool version (distinct from the factory version)
 * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
 * @param centerednessMargin How far the price can be from the center before the price range starts to move
 * @param initialMinPrice The initial minimum price of token A in terms of token B as an 18-decimal FP value
 * @param initialMaxPrice The initial maximum price of token A in terms of token B as an 18-decimal FP value
 * @param initialTargetPrice The initial target price of token A in terms of token B as an 18-decimal FP value
 * @param tokenAPriceIncludesRate Whether the amount of token A is scaled by the rate when calculating the price
 * @param tokenBPriceIncludesRate Whether the amount of token B is scaled by the rate when calculating the price
 */
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 dailyPriceShiftExponent;
    uint64 centerednessMargin;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

/**
 * @notice ReClammPool initialization parameters.
 * @dev ReClamm pools may contain wrapped tokens (with rate providers), in which case there are two options for
 * providing the initialization prices (and the initialization balances can be calculated in terms of either
 * token). If the price is that of the wrapped token, we should not apply the rate, so the flag for that token
 * should be false. If the price is given in terms of the underlying, we do need to apply the rate when computing
 * the initialization balances.
 *
 * @param initialMinPrice The initial minimum price of token A in terms of token B as an 18-decimal FP value
 * @param initialMaxPrice The initial maximum price of token A in terms of token B as an 18-decimal FP value
 * @param initialTargetPrice The initial target price of token A in terms of token B as an 18-decimal FP value
 * @param tokenAPriceIncludesRate Whether the amount of token A is scaled by the rate when calculating the price
 * @param tokenBPriceIncludesRate Whether the amount of token B is scaled by the rate when calculating the price
 */
struct ReClammPriceParams {
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

/// @notice Full interface for the ReClammPool, encompassing main and extension functions.
// wake-disable-next-line unused-contract
interface IReClammPool is IReClammPoolMain, IReClammPoolExtension {
    /// @notice The proxy implementation must point back to the main pool.
    error WrongReClammPoolExtensionDeployment();

    /// @notice The function is not implemented.
    error NotImplemented();

    /**
     * @notice The `ReClammPoolExtension` contract was called by an account directly.
     * @dev It can only be called by a ReClammPool via delegate call.
     */
    error NotPoolDelegateCall();

    /// @notice A function that requires initialization was called before the pool was initialized.
    error PoolNotInitialized();

    /// @notice The start time for the price ratio update is invalid (either in the past or after the given end time).
    error InvalidStartTime();

    /// @notice The centeredness margin is outside the valid numerical range.
    error InvalidCenterednessMargin();

    /// @notice The vault is not locked, so the pool balances are manipulable.
    error VaultIsNotLocked();

    /// @notice The pool is outside the target price range before or after the operation.
    error PoolOutsideTargetRange();

    /// @notice The initial price configuration (min, max, target) is invalid.
    error InvalidInitialPrice();

    /// @notice The daily price shift exponent is too high.
    error DailyPriceShiftExponentTooHigh();

    /// @notice The difference between end time and start time is too short for the price ratio update.
    error PriceRatioUpdateDurationTooShort();

    /// @notice The rate of change exceeds the maximum daily price ratio rate.
    error PriceRatioUpdateTooFast();

    /// @dev The price ratio being set is too close to the current one.
    error PriceRatioDeltaBelowMin(uint256 fourthRootPriceRatioDelta);

    /// @dev An attempt was made to stop the price ratio update while no update was in progress.
    error PriceRatioNotUpdating();

    /**
     * @notice `getRate` from `IRateProvider` was called on a ReClamm Pool.
     * @dev ReClamm Pools should never be nested. This is because the invariant of the pool is only used to calculate
     * swaps. When tracking the market price or shrinking or expanding the liquidity concentration, the invariant can
     * can decrease or increase independent of the balances, which makes the BPT rate meaningless.
     */
    error ReClammPoolBptRateUnsupported();

    /**
     * @notice The initial balances of the ReClamm Pool must respect the initialization ratio bounds.
     * @dev On pool creation, a theoretical balance ratio is computed from the min, max, and target prices. During
     * initialization, the actual balance ratio is compared to this theoretical value, and must fall within a fixed,
     * symmetrical tolerance range, or initialization reverts. If it were outside this range, the initial price would
     * diverge too far from the target price, and the pool would be vulnerable to arbitrage.
     */
    error BalanceRatioExceedsTolerance();

    /// @notice The current price interval or spot price is outside the initialization price range.
    error WrongInitializationPrices();

    /**
     * @notice The Price Ratio State was updated.
     * @dev This event will be emitted on initialization, and when governance initiates a price ratio update.
     * @param startFourthRootPriceRatio The fourth root price ratio at the start of an update
     * @param endFourthRootPriceRatio The fourth root price ratio at the end of an update
     * @param priceRatioUpdateStartTime The timestamp when the update begins
     * @param priceRatioUpdateEndTime The timestamp when the update ends
     */
    event PriceRatioStateUpdated(
        uint256 startFourthRootPriceRatio,
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    );

    /**
     * @notice The virtual balances were updated after a user interaction (swap or liquidity operation).
     * @dev Unless the price range is changing, the virtual balances remain in proportion to the real balances.
     * These balances will also be updated when the centeredness margin or daily price shift exponent is changed.
     *
     * @param virtualBalanceA Offset to the real balance reserves
     * @param virtualBalanceB Offset to the real balance reserves
     */
    event VirtualBalancesUpdated(uint256 virtualBalanceA, uint256 virtualBalanceB);

    /**
     * @notice The daily price shift exponent was updated.
     * @dev This will be emitted on deployment, and when changed by governance or the swap manager.
     * @param dailyPriceShiftExponent The new daily price shift exponent
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
     */
    event DailyPriceShiftExponentUpdated(uint256 dailyPriceShiftExponent, uint256 dailyPriceShiftBase);

    /**
     * @notice The centeredness margin was updated.
     * @dev This will be emitted on deployment, and when changed by governance or the swap manager.
     * @param centerednessMargin The new centeredness margin
     */
    event CenterednessMarginUpdated(uint256 centerednessMargin);

    /**
     * @notice The timestamp of the last user interaction.
     * @dev This is emitted on every swap or liquidity operation.
     * @param lastTimestamp The timestamp of the operation
     */
    event LastTimestampUpdated(uint32 lastTimestamp);
}
