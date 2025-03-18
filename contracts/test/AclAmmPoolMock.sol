// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { AclAmmPool } from "../AclAmmPool.sol";
import { AclAmmPoolParams } from "../interfaces/IAclAmmPool.sol";

contract AclAmmPoolMock is AclAmmPool {
    constructor(AclAmmPoolParams memory params, IVault vault) AclAmmPool(params, vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setCenterednessMargin(uint256 newCenterednessMargin) external {
        _setCenterednessMargin(newCenterednessMargin);
    }
}
