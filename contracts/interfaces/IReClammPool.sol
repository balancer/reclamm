// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

/// @dev Struct with data for deploying a new ReClammPool.
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 priceShiftDailyRate;
    uint96 fourthRootPriceRatio;
    uint64 centerednessMargin;
}

interface IReClammPool is IBasePool {
    /// @dev Indicates that the start time is after the end time.
    error GradualUpdateTimeTravel(uint256 resolvedStartTime, uint256 endTime);

    /// @dev The function is not implemented.
    error NotImplemented();

    /// @dev The token balance is too low after a user operation.
    error TokenBalanceTooLow();

    /// @dev The pool centeredness is too low after a swap.
    error PoolCenterednessTooLow();

    /// @dev The Price Ratio State was updated.
    event PriceRatioStateUpdated(
        uint256 startFourthRootPriceRatio,
        uint256 endFourthRootPriceRatio,
        uint256 startTime,
        uint256 endTime
    );

    /// @dev The Virtual Balances were updated after a user interaction.
    event VirtualBalancesUpdated(uint256[] virtualBalances);

    /// @dev The Price Shift Daily Rate was updated.
    event PriceShiftDailyRateUpdated(uint256 priceShiftDailyRate);

    /// @dev The Centeredness Margin was updated.
    event CenterednessMarginUpdated(uint256 centerednessMargin);

    /**
     * @notice Returns the current virtual balances.
     * @dev The current virtual balances are calculated based on the last virtual balances. If the pool is in range
     * and price ratio is not updating, the virtual balances will not change. If pool is out of range and/or price
     * ratio is updating, this function will calculate the new virtual balances based on the timestamp of the last user
     * interaction.
     *
     * @return currentVirtualBalances The current virtual balances.
     */
    function getCurrentVirtualBalances() external view returns (uint256[] memory currentVirtualBalances);

    /// @notice Returns the last timestamp.
    function getLastTimestamp() external view returns (uint32);

    /**
     * @notice Returns the current fourth root of price ratio.
     * @dev The current fourth root of price ratio is an interpolation of the price ratio between the start and end
     * time.
     *
     * @return currentFourthRootPriceRatio The current fourth root of price ratio.
     */
    function getCurrentFourthRootPriceRatio() external view returns (uint96);

    /**
     * @notice Updates the price ratio state.
     * @dev The price ratio is calculated by interpolating between the start and end time. The start price ratio is the
     * current price ratio of the pool.
     *
     * @param newFourthRootPriceRatio The new price ratio.
     * @param startTime The start time.
     * @param endTime The end time.
     */
    function setPriceRatioState(uint256 newFourthRootPriceRatio, uint256 startTime, uint256 endTime) external;

    /**
     * @notice Updates the price shift daily rate.
     * @dev This function is considered a user interaction, and therefore recalculates the virtual balances and sets
     * the last timestamp.
     *
     * @param newPriceShiftDailyRate The new price shift daily rate
     */
    function setPriceShiftDailyRate(uint256 newPriceShiftDailyRate) external;
}
