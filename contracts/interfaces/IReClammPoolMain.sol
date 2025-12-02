// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

interface IReClammPoolMain is IBasePool {
    /*******************************************************************************
                                   Pool State Getters
    *******************************************************************************/

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

    /*******************************************************************************
                                   Pool State Setters
    *******************************************************************************/

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

    /*******************************************************************************
                                Initialization Helpers
    *******************************************************************************/

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

    /*******************************************************************************
                                    Proxy Functions
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
