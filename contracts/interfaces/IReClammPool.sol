// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IReClammPoolExtension } from "./IReClammPoolExtension.sol";
import { IReClammPoolMain } from "./IReClammPoolMain.sol";
import { IReClammEvents } from "./IReClammEvents.sol";
import { IReClammErrors } from "./IReClammErrors.sol";

interface IReClammPool is IReClammPoolMain, IReClammPoolExtension, IReClammErrors, IReClammEvents {
    // solhint-disable-previous-line no-empty-blocks
}
