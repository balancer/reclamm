// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IReClammPoolExtension } from "./IReClammPoolExtension.sol";
import { IReClammPoolMain } from "./IReClammPoolMain.sol";

/// @dev Struct with data for deploying a new ReClammPool.
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 dailyPriceShiftExponent;
    uint64 centerednessMargin;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

/// @notice Full interface for the ReClammPool, encompassing main and extension functions.
// wake-disable-next-line unused-contract
interface IReClammPool is IReClammPoolMain, IReClammPoolExtension {
    // solhint-disable-previous-line no-empty-blocks
}
