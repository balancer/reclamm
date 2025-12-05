// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

interface IReClammErrors {
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
}
