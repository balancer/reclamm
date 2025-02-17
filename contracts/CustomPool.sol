// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {BalancerPoolToken} from "@balancer-v3/vault/contracts/vault/contracts/BalancerPoolToken.sol";
import {PoolInfo} from "@balancer-v3/vault/contracts/vault/contracts/PoolInfo.sol";
import {Version} from "@balancer-v3/vault/contracts/vault/contracts/Version.sol";

contract CustomPool is BalancerPoolToken, PoolInfo, Version {
    constructor(
        
    )
}