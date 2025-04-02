// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPool } from "../ReClammPool.sol";
import { ReClammPoolParams } from "../interfaces/IReClammPool.sol";
import { ReClammMath } from "../lib/ReClammMath.sol";

contract ReClammPoolMock is ReClammPool {
    constructor(ReClammPoolParams memory params, IVault vault) ReClammPool(params, vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setLastTimestamp(uint256 newLastTimestamp) external {
        _lastTimestamp = SafeCast.toUint32(newLastTimestamp);
    }

    function isPoolInRange() external view returns (bool) {
        return _isPoolInRange();
    }

    function calculatePoolCenteredness() external view returns (uint256) {
        (, , , uint256[] memory currentBalancesScaled18) = _vault.getPoolTokenInfo(address(this));
        return ReClammMath.calculateCenteredness(currentBalancesScaled18, _lastVirtualBalances);
    }
}
