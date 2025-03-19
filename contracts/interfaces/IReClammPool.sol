// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

/// @dev Struct with data for deploying a new ReClammPool.
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 increaseDayRate;
    uint256 sqrtQ0;
    uint256 centerednessMargin;
}

interface IReClammPool is IBasePool {
    /// @dev Indicates that the start time is after the end time.
    error GradualUpdateTimeTravel(uint256 resolvedStartTime, uint256 endTime);

    /// @dev The function is not implemented.
    error NotImplemented();

    event SqrtQ0Updated(uint256 startSqrtQ0, uint256 endSqrtQ0, uint256 startTime, uint256 endTime);
    event ReClammPoolInitialized(uint256 increaseDayRate, uint256 sqrtQ0, uint256 centernessMargin);

    function getLastVirtualBalances() external view returns (uint256[] memory virtualBalances);

    function getLastTimestamp() external view returns (uint256);

    function getCurrentSqrtQ0() external view returns (uint256);

    function setSqrtQ0(uint256 newSqrtQ0, uint256 startTime, uint256 endTime) external;
}
