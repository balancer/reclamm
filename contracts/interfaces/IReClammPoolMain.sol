// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

import { PriceRatioState } from "../lib/ReClammMath.sol";

interface IReClammPoolMain is IBasePool {
    /********************************************************
                       Pool State Getters
    ********************************************************/

    /**
     * @notice Compute the initialization amounts, given a reference token and amount.
     * @dev Convenience function to compute the initial funding amount for the second token, given the first. It
     * returns the amount of tokens in raw amounts, which can be used as-is to initialize the pool using a standard
     * router.
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

    /********************************************************
                       Pool State Setters
    ********************************************************/

    /**
     * @notice Initiates a price ratio update by setting a new ending price ratio and time interval.
     * @dev The price ratio is calculated by interpolating between the start and end times. The start price ratio will
     * be set to the current fourth root price ratio of the pool. This is a permissioned function.
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
     */
    function stopPriceRatioUpdate() external;

    /**
     * @notice Updates the daily price shift exponent, as a 18-decimal FP percentage.
     * @dev This function is considered a user interaction, and therefore recalculates the virtual balances and sets
     * the last timestamp. This is a permissioned function.
     *
     * A percentage of 100% will make the price range double (or halve) within a day.
     * A percentage of 200% will make the price range quadruple (or quartered) within a day.
     *
     * More generically, the new price range will be either
     * Range_old * 2^(newDailyPriceShiftExponent / 100), or
     * Range_old / 2^(newDailyPriceShiftExponent / 100)
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
     * @param newCenterednessMargin The new centeredness margin
     */
    function setCenterednessMargin(uint256 newCenterednessMargin) external;

    /*******************************************************************************
                                     Miscellaneous
    *******************************************************************************/

    /**
     * @notice Returns the ReClammPoolExtension contract address.
     * @dev The ReClammPoolExtension handles less critical or frequently used functions, since delegate calls through
     * the ReClammPool are more expensive than direct calls.
     *
     * @return reClammPoolExtension Address of the extension contract
     */
    function getReClammPoolExtension() external view returns (address reClammPoolExtension);
}
