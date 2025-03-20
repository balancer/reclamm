// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

/// @dev Struct with data for deploying a new ReClammPool.
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 increaseDayRate;
    uint256 sqrtPriceRatio;
    uint256 centerednessMargin;
}

interface IReClammPool is IBasePool {
    /// @dev Indicates that the start time is after the end time.
    error GradualUpdateTimeTravel(uint256 resolvedStartTime, uint256 endTime);

    /// @dev The function is not implemented.
    error NotImplemented();

    event SqrtPriceRatioUpdated(
        uint256 startSqrtPriceRatio,
        uint256 endSqrtPriceRatio,
        uint256 startTime,
        uint256 endTime
    );

    event VirtualBalancesUpdated(uint256[] virtualBalances);

    event IncreaseDayRateUpdated(uint256 increaseDayRate);

    event CenterednessMarginUpdated(uint256 centerednessMargin);

    function getLastVirtualBalances() external view returns (uint256[] memory virtualBalances);

    function getLastTimestamp() external view returns (uint256);

    function getCurrentSqrtPriceRatio() external view returns (uint256);

    function setSqrtPriceRatio(uint256 newSqrtPriceRatio, uint256 startTime, uint256 endTime) external;

    function setIncreaseDayRate(uint256 newIncreaseDayRate) external;
}
