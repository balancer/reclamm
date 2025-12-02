// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

interface IReClammPoolMain is IBasePool {
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
