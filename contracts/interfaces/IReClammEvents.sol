// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

interface IReClammEvents {
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
