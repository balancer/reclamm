// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { a, b } from "./ReClammMath.sol";

library ReClammHelperLib {

    function getTokenRates(IVault vault, address pool) internal view returns (uint256 rateA, uint256 rateB) {
        (, TokenInfo[] memory tokenInfo, , ) = vault.getPoolTokenInfo(pool);

        rateA = _getTokenRate(tokenInfo[a]);
        rateB = _getTokenRate(tokenInfo[b]);
    }

    function _getTokenRate(TokenInfo memory tokenInfo) internal view returns (uint256) {
        return tokenInfo.tokenType == TokenType.WITH_RATE ? tokenInfo.rateProvider.getRate() : FixedPoint.ONE;
    }
}