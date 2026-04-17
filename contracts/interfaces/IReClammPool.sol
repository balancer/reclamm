// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

import { PriceRatioState } from "../lib/ReClammMath.sol";

/// @dev Struct with data for deploying a new ReClammPool.
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
 * @notice ReClamm Pool data that cannot change after deployment.
 * @dev Note that the initial prices are used only during pool initialization. After the initialization, the prices
 * will shift according to price ratio and pool centeredness.
 *
 * @param tokens Pool tokens, sorted in token registration order
 * @param decimalScalingFactors Adjust for token decimals to retain calculation precision. FP(1) for 18-decimal tokens
 * @param tokenAPriceIncludesRate True if the prices incorporate a rate for token A
 * @param tokenBPriceIncludesRate True if the prices incorporate a rate for token B
 * @param minSwapFeePercentage The minimum allowed static swap fee percentage; mitigates precision loss due to rounding
 * @param maxSwapFeePercentage The maximum allowed static swap fee percentage
 * @param initialMinPrice The initial minimum price of token A in terms of token B (possibly applying rates)
 * @param initialMaxPrice The initial maximum price of token A in terms of token B (possibly applying rates)
 * @param initialTargetPrice The initial target price of token A in terms of token B (possibly applying rates)
 * @param initialDailyPriceShiftExponent The initial daily price shift exponent
 * @param initialCenterednessMargin The initial centeredness margin (threshold for initiating a range update)
 * @param minPriceRatio The minimum price ratio (max price / min price) allowed for the pool, as an 18-decimal FP value
 * @param maxCenterednessMargin The maximum centeredness margin for the pool, as an 18-decimal FP percentage
 * @param maxDailyPriceShiftExponent The maximum exponent for the pool's price shift, as an 18-decimal FP percentage
 * @param maxDailyPriceRatioUpdateRate The maximum percentage the price range can expand/contract per day
 * @param minPriceRatioUpdateDuration The minimum duration for the price ratio update, expressed in seconds
 * @param minPriceRatioDelta The minimum absolute difference between current and new price ratio
 * @param balanceRatioAndPriceTolerance The maximum amount initialized pool parameters can deviate from ideal values
 */
struct ReClammPoolImmutableData {
    // Base Pool
    IERC20[] tokens;
    uint256[] decimalScalingFactors;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
    uint256 minSwapFeePercentage;
    uint256 maxSwapFeePercentage;
    // Initialization
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    uint256 initialDailyPriceShiftExponent;
    uint256 initialCenterednessMargin;
    // Operating Limits
    uint256 minPriceRatio;
    uint256 maxPriceRatio;
    uint256 maxCenterednessMargin;
    uint256 maxDailyPriceShiftExponent;
    uint256 maxDailyPriceRatioUpdateRate;
    uint256 minPriceRatioUpdateDuration;
    uint256 minPriceRatioDelta;
    uint256 balanceRatioAndPriceTolerance;
}

/**
 * @notice Snapshot of current ReClamm Pool data that can change.
 * @dev Note that live balances will not necessarily be accurate if the pool is in Recovery Mode. Withdrawals
 * in Recovery Mode bypass hooks, so virtual balances are not scaled down along with the real balances. If there
 * are withdrawals, raw and live balances will be out of sync until Recovery Mode is disabled.
 *
 * Normally pools that go into recovery do not come back, but it is possible. If so, the pool would operate post-
 * recovery with inflated virtual depth. Proportional withdrawals scale Ra and Rb by the same factor, leaving
 * centeredness unchanged, so the out-of-range VB shift does not trigger. Asymmetric swaps may gradually shift
 * centeredness and eventually trigger recalibration, but this is not guaranteed. `setDailyPriceShiftExponent`
 * and `setCenterednessMargin` do not recompute VBs from real balances; they only adjust their respective parameter.
 * The only reliable recalibration path is `startPriceRatioUpdate` with a target that forces VB recomputation.
 *
 * Note: disabling Recovery Mode on a ReClamm pool after withdrawals have occurred is not recommended. The inflated
 * virtual balances cannot be fully corrected without a price ratio update, and the pool's swap curve will not price
 * accurately until that recalibration is performed. Governance should treat Recovery Mode as one-way for this pool
 * type.
 *
 * Base Pool:
 * @param balancesLiveScaled18 Token balances after paying yield fees, applying decimal scaling and rates
 * @param tokenRates 18-decimal FP values for rate tokens (e.g., yield-bearing), or FP(1) for standard tokens
 * @param staticSwapFeePercentage 18-decimal FP value of the static swap fee percentage
 * @param totalSupply The current total supply of the pool tokens (BPT)
 *
 * ReClamm:
 * @param lastTimestamp The timestamp of the last user interaction
 * @param lastVirtualBalances The last virtual balances of the pool
 * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
 * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
 * @param centerednessMargin The centeredness margin of the pool
 * @param currentPriceRatio The current price ratio, an interpolation of the price ratio state
 * @param currentFourthRootPriceRatio The current fourth root price ratio (stored in the price ratio state)
 * @param startFourthRootPriceRatio The fourth root price ratio at the start of an update
 * @param endFourthRootPriceRatio The fourth root price ratio at the end of an update
 * @param priceRatioUpdateStartTime The timestamp when the update begins
 * @param priceRatioUpdateEndTime The timestamp when the update ends
 *
 * Pool State:
 * @param isPoolInitialized If false, the pool has not been seeded with initial liquidity, so operations will revert
 * @param isPoolPaused If true, the pool is paused, and all non-recovery-mode state-changing operations will revert
 * @param isPoolInRecoveryMode If true, Recovery Mode withdrawals are enabled, and live balances may be inaccurate
 */
struct ReClammPoolDynamicData {
    // Base Pool
    uint256[] balancesLiveScaled18;
    uint256[] tokenRates;
    uint256 staticSwapFeePercentage;
    uint256 totalSupply;
    // ReClamm
    uint256 lastTimestamp;
    uint256[] lastVirtualBalances;
    uint256 dailyPriceShiftExponent;
    uint256 dailyPriceShiftBase;
    uint256 centerednessMargin;
    uint256 currentPriceRatio;
    uint256 currentFourthRootPriceRatio;
    uint256 startFourthRootPriceRatio;
    uint256 endFourthRootPriceRatio;
    uint32 priceRatioUpdateStartTime;
    uint32 priceRatioUpdateEndTime;
    // Pool State
    bool isPoolInitialized;
    bool isPoolPaused;
    bool isPoolInRecoveryMode;
}

/**
 * @notice Interface for the ReClamm Pool.
 * @dev Extends the Balancer Base Pool with additional state and functions for dynamic price ranges and virtual
 * balance, specific to ReClamm pools. The view functions are designed to be called off-chain by a frontend or
 * monitoring bot, and should not be used as on-chain price or state oracles.
 */
interface IReClammPool is IBasePool {
    /********************************************************
                           Events
    ********************************************************/

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

    /********************************************************
                           Errors
    ********************************************************/

    /// @notice The function is not implemented.
    error NotImplemented();

    /// @notice The centeredness margin is outside the valid numerical range.
    error InvalidCenterednessMargin();

    /// @notice The vault is not locked, so the pool balances are manipulable.
    error VaultIsNotLocked();

    /// @notice The pool is outside the target price range before or after the operation.
    error PoolOutsideTargetRange();

    /// @notice The start time for the price ratio update is invalid (either in the past or after the given end time).
    error InvalidStartTime();

    /// @notice An initial price parameter is invalid: zero, or the target falls outside the [min, max] range.
    error InvalidInitialPrice();

    /// @notice The initial target price is outside the target range.
    error InvalidInitialTargetPrice();

    /// @notice The daily price shift exponent is too high.
    error DailyPriceShiftExponentTooHigh();

    /// @notice A nonzero daily price shift exponent is below the minimum resolution of the internal conversion.
    error DailyPriceShiftExponentTooLow();

    /// @notice The price ratio is too low.
    error PriceRatioBelowMin(uint256 priceRatio);

    /// @notice The price ratio is too high.
    error PriceRatioAboveMax(uint256 priceRatio);

    /// @notice The difference between end time and start time is too short for the price ratio update.
    error PriceRatioUpdateDurationTooShort();

    /// @notice The rate of change exceeds the maximum daily price ratio rate.
    error PriceRatioUpdateTooFast();

    /**
     * @notice The price ratio being set is too close to the current one.
     * @param priceRatioDelta The absolute difference between the current and new price ratios
     */
    error PriceRatioDeltaBelowMin(uint256 priceRatioDelta);

    /// @notice An attempt was made to stop the price ratio update while no update was in progress.
    error PriceRatioNotUpdating();

    /**
     * @notice `getRate` from `IRateProvider` was called on a ReClamm Pool.
     * @dev ReClamm Pools should never be nested. This is because the invariant of the pool is only used to calculate
     * swaps. When tracking the market price or shrinking or expanding the liquidity concentration, the invariant can
     * can decrease or increase independent of the balances, which makes the BPT rate meaningless.
     */
    error ReClammPoolBptRateUnsupported();

    /// @notice `onBeforeInitialize` hook was called more than once.
    error PoolAlreadyInitialized();

    /// @notice Function called before initializing the pool.
    error PoolNotInitialized();

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
     * @notice The hook was invoked with the wrong pool address.
     * @param pool The address of the pool that was passed to the hook
     */
    error InvalidPoolArgument(address pool);

    /**
     * @notice A proportional removal would scale a virtual balance to zero.
     * @dev Reverted from `onBeforeRemoveLiquidity` when the post-scaling virtual balances would integer-truncate
     * to zero. This is only reachable when a sole (or effectively sole) LP burns enough BPT that
     * `(oldVirtualBalance * bptDelta) / oldTotalSupply` rounds down to zero. Allowing it through would brick the
     * pool, since `computePriceRatio` then divides by zero on every subsequent call.
     */
    error ZeroVirtualBalance();

    /********************************************************
                       Stored State Getters
    ********************************************************/

    // The getters in this section return values directly from storage. They perform no virtual-balance math and are
    // safe to call before the pool has been initialized; they will simply return zero values for state that hasn't
    // been set yet.

    /**
     * @notice Getter for the timestamp of the last user interaction.
     * @return lastTimestamp The timestamp of the operation
     */
    function getLastTimestamp() external view returns (uint32 lastTimestamp);

    /**
     * @notice Getter for the last virtual balances.
     * @return lastVirtualBalanceA  The last virtual balance of token A
     * @return lastVirtualBalanceB  The last virtual balance of token B
     */
    function getLastVirtualBalances() external view returns (uint256 lastVirtualBalanceA, uint256 lastVirtualBalanceB);

    /**
     * @notice Returns the centeredness margin.
     * @dev The centeredness margin defines how closely an unbalanced pool can approach the limits of the total price
     * range and still be considered within the target range. The margin is symmetrical. If it's 20%, the target
     * range is defined as >= 20% above the lower bound and <= 20% below the upper bound.
     *
     * @return centerednessMargin The current centeredness margin
     */
    function getCenterednessMargin() external view returns (uint256 centerednessMargin);

    /**
     * @notice Returns the daily price shift exponent as an 18-decimal FP.
     * @dev At 100%, when the pool is outside its target range, the price range shifts toward the current market
     * price at approximately 2x per day. The exact rate is state-dependent: it equals 2^exponent per day when the
     * out-of-range side holds no real balance, and is faster otherwise.
     * @return dailyPriceShiftExponent The daily price shift exponent
     */
    function getDailyPriceShiftExponent() external view returns (uint256 dailyPriceShiftExponent);

    /**
     * @notice Returns the internal time constant representation for the daily price shift exponent (tau).
     * @dev Equals 1 - dailyPriceShiftExponent / _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT.
     * @return dailyPriceShiftBase The internal representation for the daily price shift exponent
     */
    function getDailyPriceShiftBase() external view returns (uint256 dailyPriceShiftBase);

    /**
     * @notice Returns the current price ratio state.
     * @dev This includes start and end values for the fourth root price ratio, and start and end times for the update.
     * @return priceRatioState The current price ratio state
     */
    function getPriceRatioState() external view returns (PriceRatioState memory priceRatioState);

    /********************************************************
                        Live State Getters
    ********************************************************/

    // The getters in this section all derive their results from live balances + time-adjusted virtual balances.
    // Before initialization, the virtual balances are zero (they're set in `onBeforeInitialize`), so the underlying
    // math is undefined: it would either revert with a low-level division-by-zero or return a numerically meaningless
    // value like centeredness 0 (which would otherwise mean "the pool is at the edge of its price range"). To make
    // this state explicit and give callers a clean error rather than an arithmetic failure, these functions revert
    // with `PoolNotInitialized` when called on a created-but-uninitialized pool.
    //
    // `computeCurrentPriceRange` (the first function below) is the one documented exception: it returns the
    // configured `initialMinPrice` / `initialMaxPrice` before init, because the configured range is a meaningful
    // answer to "what range will this pool operate in?". The other concepts (price ratio, virtual balances,
    // centeredness, within-range) have no comparable meaningful pre-init answer.
    //
    // Callers wanting the configured initial values (e.g. the implied initial price ratio) should read them from
    // `getReClammPoolImmutableData()` and compute as needed, not call these getters.

    /**
     * @notice Computes the current total price range.
     * @dev Prices represent the value of token A denominated in token B (i.e., how many B tokens equal the value of
     * one A token).
     *
     * The "target" range is then defined as a subset of this total price range, with the margin trimmed symmetrically
     * from each side. The pool endeavors to adjust this range as necessary to keep the current market price within it.
     *
     * This function uses current live balances and time-adjusted virtual balances. Note that, unlike the other
     * `compute*` getters on this interface, this function does NOT revert before initialization: it returns the
     * configured `initialMinPrice` / `initialMaxPrice` instead. The configured range is a meaningful answer to "what
     * range will this pool operate in?" even before the pool has live balances; the same is not true of the price
     * ratio, virtual balances, centeredness, or in-range status, which all revert with `PoolNotInitialized`.
     *
     * @return minPrice The lower limit of the current total price range
     * @return maxPrice The upper limit of the current total price range
     */
    function computeCurrentPriceRange() external view returns (uint256 minPrice, uint256 maxPrice);

    /**
     * @notice Computes the current virtual balances and a flag indicating whether they have changed.
     * @dev The current virtual balances are calculated based on the last virtual balances. If the pool is within the
     * target range and the price ratio is not updating, the virtual balances will not change. If the pool is outside
     * the target range, or the price ratio is updating, this function will calculate the new virtual balances based on
     * the timestamp of the last user interaction. Note that virtual balances are always scaled18 values.
     *
     * This function uses current live balances and time-adjusted virtual balances. Reverts with `PoolNotInitialized`
     * if called before initialization, since virtual balances are zero in that state.
     *
     * @return currentVirtualBalanceA The current virtual balance of token A
     * @return currentVirtualBalanceB The current virtual balance of token B
     * @return changed Whether the current virtual balances are different from `lastVirtualBalances`
     */
    function computeCurrentVirtualBalances()
        external
        view
        returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed);

    /**
     * @notice Computes the current price ratio.
     * @dev The price ratio is the ratio of the max price to the min price, according to current real and virtual
     * balances.
     *
     * Reverts with `PoolNotInitialized` if called before initialization, since virtual balances are zero in that
     * state and there is no live price ratio to compute. Callers wanting the configured initial ratio should derive
     * it from `getReClammPoolImmutableData()` (`initialMaxPrice / initialMinPrice`).
     *
     * @return currentPriceRatio The current price ratio
     */
    function computeCurrentPriceRatio() external view returns (uint256 currentPriceRatio);

    /**
     * @notice Computes the current fourth root of price ratio.
     * @dev The price ratio is the ratio of the max price to the min price, according to current real and virtual
     * balances. This function returns its fourth root.
     *
     * Reverts with `PoolNotInitialized` if called before initialization, since virtual balances are zero in that
     * state and there is no live price ratio to compute. Callers wanting the configured initial ratio should derive
     * it from `getReClammPoolImmutableData()` (`initialMaxPrice / initialMinPrice`).
     *
     * @return currentFourthRootPriceRatio The current fourth root of price ratio
     */
    function computeCurrentFourthRootPriceRatio() external view returns (uint256 currentFourthRootPriceRatio);

    /**
     * @notice Compute the current pool centeredness (a measure of how unbalanced the pool is).
     * @dev A value of 0 means the pool is at the edge of the price range (i.e., one of the real balances is zero).
     * A value of FixedPoint.ONE means the balances (and market price) are exactly in the middle of the range.
     *
     * This function uses live balances (rate-scaled and yield-fee-adjusted from the last settled state) and time-
     * adjusted virtual balances. Callers should not use this as a security gate within a Vault transaction, as the
     * vault may be unlocked and balances manipulable via transient liquidity. It is meant to be called off-chain.
     *
     * Reverts with `PoolNotInitialized` if called before initialization. Without it, the underlying math would
     * short-circuit to a centeredness of 0 (because real balances are zero), which would falsely suggest the pool
     * is at the edge of its price range rather than uninitialized.
     *
     * @return poolCenteredness The current pool centeredness (as an 18-decimal FP value)
     * @return isPoolAboveCenter True if the pool is above the center, false otherwise
     */
    function computeCurrentPoolCenteredness() external view returns (uint256 poolCenteredness, bool isPoolAboveCenter);

    /**
     * @notice Compute whether the pool is within the target price range.
     * @dev The pool is considered to be in the target range when the centeredness is greater than or equal to the
     * centeredness margin (i.e., the price is within the subset of the total price range defined by the
     * centeredness margin).
     *
     * This function uses live balances (rate-scaled and yield-fee-adjusted from the last settled state) and time-
     * adjusted virtual balances. Callers should not use this as a security gate within a Vault transaction, as the
     * vault may be unlocked and balances manipulable via transient liquidity. It is meant to be called off-chain.
     *
     * Reverts with `PoolNotInitialized` if called before initialization, since "in target range" is undefined when
     * there are no live balances to compare against the margin.
     *
     * @return isWithinTargetRange True if pool centeredness is greater than or equal to the centeredness margin
     */
    function isPoolWithinTargetRange() external view returns (bool isWithinTargetRange);

    /********************************************************
                        Off-chain Helpers
    ********************************************************/

    // The functions in this section are intended to be called off-chain (deployment scripts, frontends, monitoring
    // bots) rather than from other contracts. Each handles its own pre-initialization story internally where relevant.

    /**
     * @notice Compute the initialization amounts, given a reference token and amount.
     * @dev Convenience function to compute the initial funding amount for the second token, given the first. It
     * returns the amount of tokens in raw amounts, which can be used as-is to initialize the pool using a standard
     * router. It is meant to be called off-chain by a deployment script or frontend.
     *
     * @param referenceToken The token whose amount is known
     * @param referenceAmountInRaw The amount of the reference token to be used for initialization, in raw amounts
     * @return initialBalancesRaw Initialization raw balances sorted in token registration order, including the given
     * amount and a calculated raw amount for the other token
     */
    function computeInitialBalancesRaw(
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw);

    /**
     * @notice Get dynamic pool data relevant to swap/add/remove calculations.
     * @dev This is meant to be called off-chain (e.g., by a frontend / monitor).
     *
     * Unlike the `compute*` getters in the Live State section, this function does NOT revert before initialization:
     * it leaves the live-state-derived fields zeroed out so that integrations can still inspect the static fields
     * (rates, fees, supply) on a freshly deployed pool.
     *
     * @return data A struct containing all dynamic ReClamm pool parameters
     */
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data);

    /**
     * @notice Get immutable pool data relevant to swap/add/remove calculations.
     * @dev This is meant to be called off-chain (e.g., by a frontend / monitor).
     * @return data A struct containing all immutable ReClamm pool parameters
     */
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data);

    /********************************************************
                       Pool State Setters
    ********************************************************/

    /**
     * @notice Initiates a price ratio update by setting a new ending price ratio and time interval.
     * @dev The price ratio is calculated by interpolating between the start and end times. The start price ratio will
     * be set to the current fourth root price ratio of the pool. This is a permissioned function.
     *
     * Unlike `setDailyPriceShiftExponent` and `setCenterednessMargin`, this function does not require
     * `onlyWhenVaultIsLocked`. This is intentional. Adding the lock requirement would introduce a DoS vector:
     * an attacker could keep the Vault perpetually unlocked (e.g., via MEV) to prevent governance from calling this
     * function. `onlyWhenVaultIsLocked` is also not effective protection for admin setters in general, because a
     * caller can lock the Vault after manipulating balances (flash loan, swap, exit callback, then call the setter).
     * The real protection is that this is a permissioned function: the caller is trusted to execute it in a clean
     * context (i.e., not from within a Vault callback or in the same transaction as a balance-manipulating operation).
     *
     * This function calls `_updateVirtualBalances()`, which reads live Vault balances. However, if a swap has
     * already occurred in the current block, `_updateVirtualBalances()` short-circuits because `lastTimestamp`
     * equals `block.timestamp`, so virtual balances are not recomputed from potentially distorted balances.
     * The start price ratio anchor is still derived from current live balances and existing virtual balances,
     * so the caller should ensure balances are not transiently manipulated when this function is called.
     *
     * In any case, trusted execution contexts are always preferable when calling permissioned functions from multisigs
     * (i.e. sign and execute right after the last signature, without giving away the execution to a frontrunner).
     *
     * @param endPriceRatio The new ending value of the price ratio, as a floating point value (e.g., 8 = 8e18)
     * @param priceRatioUpdateStartTime The timestamp when the price ratio update will start
     * @param priceRatioUpdateEndTime The timestamp when the price ratio update will end
     * @return actualPriceRatioUpdateStartTime The actual start time for the price ratio update (min: block.timestamp).
     */
    function startPriceRatioUpdate(
        uint256 endPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) external returns (uint256 actualPriceRatioUpdateStartTime);

    /**
     * @notice Stops an ongoing price ratio update.
     * @dev The price ratio is calculated by interpolating between the start and end times. The new end price ratio
     * will be set to the current one at the current timestamp, effectively pausing the update.
     * This is a permissioned function.
     *
     * Does not require `onlyWhenVaultIsLocked` for the same reasons as `startPriceRatioUpdate`; see its
     * documentation for the details.
     *
     * Trusted execution contexts are always preferable when calling permissioned functions from multisigs
     * (i.e. sign and execute right after the last signature, without giving away the execution to a frontrunner).
     *
     */
    function stopPriceRatioUpdate() external;

    /**
     * @notice Updates the daily price shift exponent, as a 18-decimal FP percentage.
     * @dev This function is considered a user interaction, and therefore recalculates the virtual balances and sets
     * the last timestamp. This is a permissioned function.
     *
     * At 100%, when the pool is outside its target range, the price range shifts toward the current market
     * price at approximately 2x per day. At 200%, approximately 4x per day.
     *
     * More generically, the price range shifts by approximately
     * 2^(newDailyPriceShiftExponent / 100) per day, or its reciprocal.
     *
     * The exact rate is state-dependent: it equals 2^exponent per day when the out-of-range side holds no real
     * balance, and is faster otherwise.
     *
     * The daily price shift rate interacts with the swap fee to determine the pool's resistance to round-trip
     * repricing extraction. When the pool is out of range, virtual balances decay over time; an actor who pushes the
     * pool past the centeredness margin and later unwinds against the repriced curve can profit if enough time passes.
     * The minimum wait before such a round trip breaks even (the "breakeven time") scales linearly with the swap fee
     * and inversely with the shift rate:
     *
     *   breakeven_seconds ~= T_ref * (swap_fee_pct / fee_ref) * (shift_ref / shift_rate_pct)
     *
     * where `swap_fee_pct` is the pool's swap fee as a percentage and `shift_rate_pct` is this exponent expressed as a
     * percentage (e.g., 5 for 5%). The reference point (T_ref = 47s, fee_ref = 0.001%, shift_ref = 5%) is the
     * empirically observed first-profitable timestamp from `ReClammRoundTripDesignRiskTest` at the pool's minimum swap
     * fee and a representative production shift rate. Rearranging, the minimum swap fee that preserves a 47-second
     * breakeven at a given shift rate:
     *
     *   min_safe_fee = fee_ref * (shift_rate_pct / shift_ref)
     *                = 0.001% * (shift_rate_pct / 5%)
     *
     * At the pool's minimum fee of 0.001%, shift rates up to 5% are covered. Higher shift rates require a
     * proportionally higher fee. At 47 seconds (~4 Ethereum mainnet blocks), empirical MEV research shows that drastic
     * price dislocations on monitored pools are corrected within 1-2 blocks - and larger dislocations are corrected
     * faster, not slower, making this a conservative bound in practice. This constraint cannot be enforced on-chain,
     * because the shift rate and swap fee are governed independently. Operators should verify the swap fee is adequate
     * whenever the shift rate is adjusted upward.
     *
     * In any case, trusted execution contexts are always preferable when calling permissioned functions from multisigs
     * (i.e. sign and execute right after the last signature, without giving away the execution to a frontrunner).
     *
     * @param newDailyPriceShiftExponent The new daily price shift exponent
     * @return actualNewDailyPriceShiftExponent The actual new daily price shift exponent, after accounting for
     * precision loss incurred when dealing with the internal representation of the exponent
     */
    function setDailyPriceShiftExponent(
        uint256 newDailyPriceShiftExponent
    ) external returns (uint256 actualNewDailyPriceShiftExponent);

    /**
     * @notice Set the centeredness margin.
     * @dev This function is considered a user action, so it will update the last timestamp and virtual balances.
     * This is a permissioned function.
     *
     * Trusted execution contexts are always preferable when calling permissioned functions from multisigs
     * (i.e. sign and execute right after the last signature, without giving away the execution to a frontrunner).
     *
     * @param newCenterednessMargin The new centeredness margin
     */
    function setCenterednessMargin(uint256 newCenterednessMargin) external;
}
