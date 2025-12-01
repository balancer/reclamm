// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IReClammPoolExtension } from "./IReClammPoolExtension.sol";
import { IReClammPoolMain } from "./IReClammPoolMain.sol";
import { IReClammEvents } from "./IReClammEvents.sol";
import { IReClammErrors } from "./IReClammErrors.sol";

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

interface IReClammPool is IReClammPoolMain, IReClammPoolExtension, IReClammErrors, IReClammEvents {
    // solhint-disable-previous-line no-empty-blocks
}
