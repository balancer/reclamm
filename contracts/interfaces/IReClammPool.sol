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
    uint256 priceShiftDailyRate;
    uint64 centerednessMargin;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
}

/**
 * @notice ReClamm Pool data that cannot change after deployment.
 * @dev Note that the initial prices are used only during pool initialization. After the initialization, the prices
 * will shift according to price ratio and pool centeredness.
 *
 * @param tokens Pool tokens, sorted in token registration order
 * @param decimalScalingFactors Conversion factor used to adjust for token decimals for uniform precision in
 * calculations. FP(1) for 18-decimal tokens
 * @param initialMinPrice The initial minimum price of the pool
 * @param initialMaxPrice The initial maximum price of the pool
 * @param initialTargetPrice The initial target price of the pool
 * @param minCenterednessMargin The minimum centeredness margin for the pool, as a percentage in 18-decimal FP.
 * @param maxCenterednessMargin The maximum centeredness margin for the pool, as a percentage in 18-decimal FP.
 * @param minTokenBalanceScaled18 The minimum token balance for the pool, scaled to 18 decimals.
 * @param maxPriceShiftDailyRate The maximum daily rate for the pool's price shift, as a percentage in 18-decimal FP.
 * @param minPriceRatioUpdateDuration The minimum duration for the price ratio update, expressed in seconds.
 * @param minPriceRatioUpdateDuration The minimum absolute difference between current and new fourth root price ratio.
 */
struct ReClammPoolImmutableData {
    IERC20[] tokens;
    uint256[] decimalScalingFactors;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    uint256 minCenterednessMargin;
    uint256 maxCenterednessMargin;
    uint256 minTokenBalanceScaled18;
    uint256 minPoolCenteredness;
    uint256 maxPriceShiftDailyRate;
    uint256 minPriceRatioUpdateDuration;
    uint256 minFourthRootPriceRatioDelta;
}

/**
 * @notice Snapshot of current ReClamm Pool data that can change.
 * @dev Note that live balances will not necessarily be accurate if the pool is in Recovery Mode. Withdrawals
 * in Recovery Mode do not make external calls (including those necessary for updating live balances), so if
 * there are withdrawals, raw and live balances will be out of sync until Recovery Mode is disabled.
 *
 * Base Pool:
 * @param balancesLiveScaled18 Token balances after paying yield fees, applying decimal scaling and rates
 * @param tokenRates 18-decimal FP values for rate tokens (e.g., yield-bearing), or FP(1) for standard tokens
 * @param staticSwapFeePercentage 18-decimal FP value of the static swap fee percentage
 * @param totalSupply The current total supply of the pool tokens (BPT)
 * ReClamm:
 * @param lastTimestamp The timestamp of the last user interaction
 * @param lastVirtualBalances The last virtual balances of the pool
 * @param priceShiftDailyRangeInSeconds The time constant of the pool
 * @param centerednessMargin The centeredness margin of the pool
 * @param currentFourthRootPriceRatio The current fourth root price ratio, an interpolation of the price ratio state
 * @param startFourthRootPriceRatio The fourth root price ratio at the start of an update
 * @param endFourthRootPriceRatio The fourth root price ratio at the end of an update
 * @param priceRatioUpdateStartTime The timestamp when the update begins
 * @param priceRatioUpdateEndTime The timestamp when the update ends
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
    uint256 priceShiftDailyRangeInSeconds;
    uint256 centerednessMargin;
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

interface IReClammPool is IBasePool {
    /********************************************************   
                           Errors
    ********************************************************/

    /// @dev The function is not implemented.
    error NotImplemented();

    /// @dev The token balance is too low after a user operation.
    error TokenBalanceTooLow();

    /// @dev The pool centeredness is too low after a swap.
    error PoolCenterednessTooLow();

    /// @dev The centeredness margin is out of range.
    error InvalidCenterednessMargin();

    /// @dev The vault is not locked, so the pool balances are manipulable.
    error VaultIsNotLocked();

    /// @dev The pool is out of range before or after the operation.
    error PoolIsOutOfRange();

    /// @dev The start time for the price ratio update is invalid (either in the past or after the given end time).
    error InvalidStartTime();

    /// @dev The daily price shift rate is too high.
    error PriceShiftDailyRateTooHigh();

    /// @dev The difference between end time and start time is too short for the price ratio update.
    error PriceRatioUpdateDurationTooShort();

    /// @dev The price ratio being set is too close to the current one.
    error FourthRootPriceRatioDeltaBelowMin(uint256 fourthRootPriceRatioDelta);

    /**
     * @notice `getRate` from `IRateProvider` was called on a ReClamm Pool.
     * @dev ReClamm Pools should never be nested. This is because the invariant of the pool is used only to calculate
     * swaps. However, when tracking the market price or shrinking/expanding the liquidity concentration, the invariant
     * can decrease/increase, which makes the BPT rate meaningless.
     */
    error ReClammPoolBptRateUnsupported();

    /// @dev Function called before initializing the pool.
    error PoolNotInitialized();
    /**
     * @notice The initial balances of the ReClamm Pool must respect the initialization ratio bounds.
     * @dev On pool creation, a theoretical balance ratio is computed from the min, max, and target prices. During
     * initialization, the actual balance ratio is compared to this theoretical value, and must fall within a fixed,
     * symmetrical tolerance range, or initialization reverts. If it were outside this range, the initial price would
     * diverge too far from the target price, and the pool would be vulnerable to arbitrage.
     */
    error BalanceRatioExceedsTolerance();

    /**
     * @notice The current price interval or spot price is outside the initialization price range.
     */
    error WrongInitializationPrices();

    /********************************************************
                           Events
    ********************************************************/

    /// @notice The Price Ratio State was updated.
    event PriceRatioStateUpdated(
        uint256 startFourthRootPriceRatio,
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    );

    /// @dev The Virtual Balances were updated after a user interaction.
    event VirtualBalancesUpdated(uint256[] virtualBalances);

    /**
     * @dev The Price Shift Daily Rate was updated.
     * @param priceShiftDailyRate The new price shift daily rate
     * @param priceShiftDailyRangeInSeconds A representation of the price shift daily rate in seconds
     */
    event PriceShiftDailyRateUpdated(uint256 priceShiftDailyRate, uint256 priceShiftDailyRangeInSeconds);

    /// @dev The Centeredness Margin was updated.
    event CenterednessMarginUpdated(uint256 centerednessMargin);

    /// @dev The timestamp of the last user interaction.
    event LastTimestampUpdated(uint32 lastTimestamp);

    /********************************************************
                       Pool State Getters
    ********************************************************/

    /**
     * @notice Computes the ratio between token balances (index 1 / index 0).
     * @dev To keep the pool within the target price range after initialization, the initial pool balances need to be
     * close to the value returned by this function. For example, if this returned 200, the initial balance of token[1]
     * should be 200 times the initial balance of token[0].
     *
     * @return balanceRatio The balance ratio that must be respected during initialization
     */
    function computeInitialBalanceRatio() external view returns (uint256 balanceRatio);

    /**
     * @notice Computes current operating price range.
     * @dev The prices are given as token A in terms of token B. The computation involves the current live balances
     * (though it should not be sensitive to them), so manipulating the result of this function is theoretically
     * possible while the Vault is unlocked. Ensure that the Vault is locked before calling this function if this
     * side effect is undesired (does not apply to off-chain calls).
     *
     * @return minPrice The lower limit of the current price range
     * @return maxPrice The upper limit of the current price range
     */
    function computeCurrentPriceRange() external view returns (uint256 minPrice, uint256 maxPrice);

    /**
     * @notice Returns the current virtual balances and a flag indicating whether they have changed.
     * @dev The current virtual balances are calculated based on the last virtual balances. If the pool is in range
     * and the price ratio is not updating, the virtual balances will not change. If the pool is out of range or the
     * price ratio is updating, this function will calculate the new virtual balances based on the timestamp of the
     * last user interaction. Note that virtual balances are always scaled18 values.
     *
     * @return currentVirtualBalances The current virtual balances
     * @return changed Whether the current virtual balances are different from `lastVirtualBalances`
     */
    function computeCurrentVirtualBalances()
        external
        view
        returns (uint256[] memory currentVirtualBalances, bool changed);

    /// @notice Returns the timestamp of the last user interaction.
    function getLastTimestamp() external view returns (uint32);

    /**
     * @notice Getter for the last virtual balances.
     * @return lastVirtualBalances The virtual balances at the time of the last user interaction
     */
    function getLastVirtualBalances() external view returns (uint256[] memory lastVirtualBalances);

    /**
     * @notice Returns the centeredness margin.
     * @dev The centeredness margin is a symmetrical measure of how closely an unbalanced pool can approach the limits
     * of the price range before the pool is considered out of range.
     *
     * @return centerednessMargin The current centeredness margin
     */
    function getCenterednessMargin() external view returns (uint256 centerednessMargin);

    /**
     * @notice Returns the time constant.
     * @dev The time constant is an internal representation of the raw price shift daily rate, expressed in seconds.
     * @return priceShiftDailyRangeInSeconds The time constant
     */
    function getPriceShiftDailyRateInSeconds() external view returns (uint256 priceShiftDailyRangeInSeconds);

    /**
     * @notice Returns the current price ratio state.
     * @dev This includes start and end values for the fourth root price ratio, and start and end times for the update.
     * @return priceRatioState The current price ratio state
     */
    function getPriceRatioState() external view returns (PriceRatioState memory priceRatioState);

    /**
     * @notice Returns the current fourth root of price ratio.
     * @dev The current fourth root of price ratio is an interpolation of the price ratio between the start and end
     * values in the price ratio state, using the percentage elapsed between the start and end times.
     *
     * @return currentFourthRootPriceRatio The current fourth root of price ratio
     */
    function computeCurrentFourthRootPriceRatio() external view returns (uint256);

    /**
     * @notice Compute whether the pool is in range (i.e., the centeredness is greater than the centeredness margin).
     * @dev This function can only be called when the vault is locked (i.e., not from inside an operation). It relies
     * on the pool balances, which can be manipulated if the Vault is unlocked.
     *
     * @return isInRange True if pool centeredness is within the centeredness margin
     */
    function isPoolInRange() external view returns (bool);

    /**
     * @notice Compute the current pool centeredness (a measure of how pool balance).
     * @dev A value of 0 means the pool is at the edge (i.e., one of the real balances is zero). A value of
     * FixedPoint.ONE means the balances (and market price) are exactly in the middle of the range.
     *
     * @return poolCenteredness The current centeredness margin (0-100% as a 18-decimal FP value)
     */
    function computeCurrentPoolCenteredness() external view returns (uint256);

    /********************************************************
                       Pool State Setters
    ********************************************************/

    /**
     * @notice Get dynamic pool data relevant to swap/add/remove calculations.
     * @return data A struct containing all dynamic ReClamm pool parameters
     */
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data);

    /**
     * @notice Get immutable pool data relevant to swap/add/remove calculations.
     * @return data A struct containing all immutable ReClamm pool parameters
     */
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data);

    /**
     * @notice Resets the price ratio update by setting a new end fourth root price ratio and time range.
     * @dev The price ratio is calculated by interpolating between the start and end times. The start price ratio will
     * be set to the current fourth root price ratio of the pool.
     *
     * @param endFourthRootPriceRatio The new ending value of the fourth root price ratio
     * @param priceRatioUpdateStartTime The timestamp when the price ratio update will start
     * @param priceRatioUpdateEndTime The timestamp when the price ratio update will end
     * @return actualPriceRatioUpdateStartTime The actual start time for the price ratio update (min: block.timestamp).
     */
    function setPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) external returns (uint256 actualPriceRatioUpdateStartTime);

    /**
     * @notice Updates the price shift daily rate.
     * @dev This function is considered a user interaction, and therefore recalculates the virtual balances and sets
     * the last timestamp.
     *
     * @param newPriceShiftDailyRate The new price shift daily rate
     */
    function setPriceShiftDailyRate(uint256 newPriceShiftDailyRate) external;

    /**
     * @notice Set the centeredness margin.
     * @dev This function is considered a user action, so it will update the last timestamp and virtual balances.
     * @param newCenterednessMargin The new centeredness margin
     */
    function setCenterednessMargin(uint256 newCenterednessMargin) external;
}
