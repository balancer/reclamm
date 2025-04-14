// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPool } from "../ReClammPool.sol";
import { ReClammPoolParams } from "../interfaces/IReClammPool.sol";

contract ReClammPoolMock is ReClammPool {
    constructor(ReClammPoolParams memory params, IVault vault) ReClammPool(params, vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setLastTimestamp(uint256 newLastTimestamp) external {
        _lastTimestamp = SafeCast.toUint32(newLastTimestamp);
    }

    function setLastVirtualBalances(uint256[] memory newLastVirtualBalances) external {
        _setLastVirtualBalances(newLastVirtualBalances);
    }
}
