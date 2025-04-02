// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

import { PriceRatioState } from "../lib/ReClammMath.sol";

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
    /********************************************************   
                           Errors
    ********************************************************/

    /// @dev Indicates that the start time is after the end time.
    error GradualUpdateTimeTravel(uint256 resolvedStartTime, uint256 endTime);

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

    /********************************************************
                           Events
    ********************************************************/

    /// @notice The Price Ratio State was updated.
    event PriceRatioStateUpdated(
        uint256 startFourthRootPriceRatio,
        uint256 endFourthRootPriceRatio,
        uint256 startTime,
        uint256 endTime
    );

    /// @dev The Virtual Balances were updated after a user interaction.
    event VirtualBalancesUpdated(uint256[] virtualBalances);

    /**
     * @dev The Price Shift Daily Rate was updated.
     * @param priceShiftDailyRate The new price shift daily rate
     * @param timeConstant A representation of the price shift daily rate in seconds
     */
    event PriceShiftDailyRateUpdated(uint256 priceShiftDailyRate, uint256 timeConstant);

    /// @dev The Centeredness Margin was updated.
    event CenterednessMarginUpdated(uint256 centerednessMargin);

    /********************************************************
                       Pool State Getters
    ********************************************************/

    /**
     * @notice Returns the current virtual balances.
     * @dev The current virtual balances are calculated based on the last virtual balances. If the pool is in range
     * and the price ratio is not updating, the virtual balances will not change. If the pool is out of range or the
     * price ratio is updating, this function will calculate the new virtual balances based on the timestamp of the
     * last user interaction. Note that virtual balances are always scaled18 values.
     *
     * @return currentVirtualBalances The current virtual balances
     */
    function getCurrentVirtualBalances() external view returns (uint256[] memory currentVirtualBalances);

    /// @notice Returns the timestamp of the last user interaction.
    function getLastTimestamp() external view returns (uint32);

    /// @notice Returns the last virtual balances.
    function getLastVirtualBalances() external view returns (uint256[] memory lastVirtualBalances);

    /**
     * @notice Returns the centeredness margin.
     * @return centerednessMargin The current centeredness margin
     */
    function getCenterednessMargin() external view returns (uint256 centerednessMargin);

    /**
     * @notice Returns the time constant.
     * @return timeConstant The time constant
     */
    function getTimeConstant() external view returns (uint256 timeConstant);

    /**
     * @notice Returns the current price ratio state.
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
    function getCurrentFourthRootPriceRatio() external view returns (uint96);

    /********************************************************
                       Pool State Setters
    ********************************************************/

    /**
     * @notice Resets the price ratio update by setting a new end fourth root price ratio and time range.
     * @dev The price ratio is calculated by interpolating between the start and end times. The start price ratio will
     * be set to the current fourth root price ratio of the pool.
     *
     * @param endFourthRootPriceRatio The new ending value of the fourth root price ratio
     * @param startTime The timestamp when the price ratio update will start
     * @param endTime The timestamp when the price ratio update will end
     */
    function setPriceRatioState(uint256 endFourthRootPriceRatio, uint256 startTime, uint256 endTime) external;

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
