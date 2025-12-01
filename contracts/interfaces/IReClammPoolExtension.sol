// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IReClammPoolMain } from "./IReClammPoolMain.sol";
import { PriceRatioState } from "../lib/ReClammMath.sol";

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
 * @param hookContract ReClamm pools are always their own hook, but also allow forwarding to an optional hook contract
 * @param maxCenterednessMargin The maximum centeredness margin for the pool, as an 18-decimal FP percentage
 * @param maxDailyPriceShiftExponent The maximum exponent for the pool's price shift, as an 18-decimal FP percentage
 * @param maxDailyPriceRatioUpdateRate The maximum percentage the price range can expand/contract per day
 * @param minPriceRatioUpdateDuration The minimum duration for the price ratio update, expressed in seconds
 * @param minPriceRatioDelta The minimum absolute difference between current and new fourth root price ratio
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
    address hookContract;
    // Operating Limits
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
 * in Recovery Mode do not make external calls (including those necessary for updating live balances), so if
 * there are withdrawals, raw and live balances will be out of sync until Recovery Mode is disabled.
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

interface IReClammPoolExtension {
    /*******************************************************************************
                              Constants and immutables
    *******************************************************************************/

    /**
     * @notice Returns the ReClammPool address.
     * @dev The ReClammPool contains the most common, critical path pool operations.
     * @return reclammPool The address of the ReClammPool
     */
    function pool() external view returns (IReClammPoolMain reclammPool);

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
     * @dev At 100% (FixedPoint.ONE), the price range doubles (or halves) within a day.
     * @return dailyPriceShiftExponent The daily price shift exponent
     */
    function getDailyPriceShiftExponent() external view returns (uint256 dailyPriceShiftExponent);

    /**
     * @notice Returns the internal time constant representation for the daily price shift exponent (tau).
     * @dev Equals dailyPriceShiftExponent / _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT.
     * @return dailyPriceShiftBase The internal representation for the daily price shift exponent
     */
    function getDailyPriceShiftBase() external view returns (uint256 dailyPriceShiftBase);

    /**
     * @notice Returns the current price ratio state.
     * @dev This includes start and end values for the fourth root price ratio, and start and end times for the update.
     * @return priceRatioState The current price ratio state
     */
    function getPriceRatioState() external view returns (PriceRatioState memory priceRatioState);

    /*******************************************************************************
                                    Pool State Getters
    *******************************************************************************/

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
     * @notice Computes the current total price range.
     * @dev Prices represent the value of token A denominated in token B (i.e., how many B tokens equal the value of
     * one A token).
     *
     * The "target" range is then defined as a subset of this total price range, with the margin trimmed symmetrically
     * from each side. The pool endeavors to adjust this range as necessary to keep the current market price within it.
     *
     * The computation involves the current live balances (though it should not be sensitive to them), so manipulating
     * the result of this function is theoretically possible while the Vault is unlocked. Ensure that the Vault is
     * locked before calling this function if this side effect is undesired (does not apply to off-chain calls).
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
     * Current virtual balances might change as a result of an operation, manipulating the value to some degree.
     * Ensure that the vault is locked before calling this function if this side effect is undesired.
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
     * @notice Computes the current target price. This is the ratio of the total (i.e., real + virtual) balances (B/A).
     * @dev Given the nature of the internal pool maths (particularly when virtual balances are shifting), it is not
     * recommended to use this pool as a price oracle.
     * @return currentTargetPrice Target price at the current pool state (real and virtual balances)
     */
    function computeCurrentSpotPrice() external view returns (uint256 currentTargetPrice);

    /**
     * @notice Computes the current fourth root of price ratio.
     * @dev The price ratio is the ratio of the max price to the min price, according to current real and virtual
     * balances. This function returns its fourth root.
     *
     * @return currentFourthRootPriceRatio The current fourth root of price ratio
     */
    function computeCurrentFourthRootPriceRatio() external view returns (uint256 currentFourthRootPriceRatio);

    /**
     * @notice Computes the current price ratio.
     * @dev The price ratio is the ratio of the max price to the min price, according to current real and virtual
     * balances.
     *
     * @return currentPriceRatio The current price ratio
     */
    function computeCurrentPriceRatio() external view returns (uint256 currentPriceRatio);

    /**
     * @notice Compute whether the pool is within the target price range.
     * @dev The pool is considered to be in the target range when the centeredness is greater than or equal to the
     * centeredness margin (i.e., the price is within the subset of the total price range defined by the centeredness
     * margin).
     *
     * Note that this function reports the state *after* the last operation. It is not very meaningful during or
     * outside an operation, as the current or next operation could change it. If this is unlikely (e.g., for high-
     * liquidity pools with high centeredness and small swaps), it may nonetheless be useful for some applications,
     * such as off-chain indicators.
     *
     * The state depends on the current balances and centeredness margin, and it uses the *last* virtual balances in
     * the calculation. This is fine because the real balances can only change during an operation, and the margin can
     * only change through the permissioned setter - both of which update the virtual balances. So it is not possible
     * for the current and last virtual balances to get out-of-sync.
     *
     * The range calculation is affected by the current live balances, so manipulating the result of this function
     * is possible while the Vault is unlocked. Ensure that the Vault is locked before calling this function if this
     * side effect is undesired (does not apply to off-chain calls).
     *
     * @return isWithinTargetRange True if pool centeredness is greater than or equal to the centeredness margin
     */
    function isPoolWithinTargetRange() external view returns (bool isWithinTargetRange);

    /**
     * @notice Compute whether the pool is within the target price range, recomputing the virtual balances.
     * @dev The pool is considered to be in the target range when the centeredness is greater than the centeredness
     * margin (i.e., the price is within the subset of the total price range defined by the centeredness margin.)
     *
     * This function is identical to `isPoolWithinTargetRange` above, except that it recomputes and uses the current
     * instead of the last virtual balances. As noted above, these should normally give the same result.
     *
     * @return isWithinTargetRange True if pool centeredness is greater than the centeredness margin
     * @return virtualBalancesChanged True if the current virtual balances would not match the last virtual balances
     */
    function isPoolWithinTargetRangeUsingCurrentVirtualBalances()
        external
        view
        returns (bool isWithinTargetRange, bool virtualBalancesChanged);

    /**
     * @notice Compute the current pool centeredness (a measure of how unbalanced the pool is).
     * @dev A value of 0 means the pool is at the edge of the price range (i.e., one of the real balances is zero).
     * A value of FixedPoint.ONE means the balances (and market price) are exactly in the middle of the range.
     *
     * The centeredness margin is affected by the current live balances, so manipulating the result of this function
     * is possible while the Vault is unlocked. Ensure that the Vault is locked before calling this function if this
     * side effect is undesired (does not apply to off-chain calls).
     *
     * @return poolCenteredness The current centeredness margin (as a 18-decimal FP value)
     * @return isPoolAboveCenter True if the pool is above the center, false otherwise
     */
    function computeCurrentPoolCenteredness() external view returns (uint256 poolCenteredness, bool isPoolAboveCenter);
}
