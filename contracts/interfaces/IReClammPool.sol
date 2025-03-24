// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

/// @dev Struct with data for deploying a new ReClammPool.
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 increaseDayRate;
    uint96 sqrtPriceRatio;
    uint256 centerednessMargin;
}

interface IReClammPool is IBasePool {
    /// @dev Indicates that the start time is after the end time.
    error GradualUpdateTimeTravel(uint256 resolvedStartTime, uint256 endTime);

    /// @dev The function is not implemented.
    error NotImplemented();

    /// @dev The token balance is too low after a user operation.
    error LowTokenBalance();

    /// @dev The pool centeredness is too low after a swap.
    error LowPoolCenteredness();

    event SqrtPriceRatioUpdated(uint96 startSqrtPriceRatio, uint96 endSqrtPriceRatio, uint32 startTime, uint32 endTime);

    event VirtualBalancesUpdated(uint256[] virtualBalances);

    event IncreaseDayRateUpdated(uint256 increaseDayRate);

    event CenterednessMarginUpdated(uint256 centerednessMargin);

    function getLastVirtualBalances() external view returns (uint256[] memory virtualBalances);

    function getLastTimestamp() external view returns (uint256);

    function getCurrentSqrtPriceRatio() external view returns (uint96);

    function setSqrtPriceRatio(uint96 newSqrtPriceRatio, uint32 startTime, uint32 endTime) external;

    function setIncreaseDayRate(uint256 newIncreaseDayRate) external;
}
