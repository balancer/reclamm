// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPoolHelper } from "../ReClammPoolHelper.sol";

/// @notice Test mock for `ReClammPoolHelper` that exposes the internal initialization-price check.
contract ReClammPoolHelperMock is ReClammPoolHelper {
    constructor(IVault vault_) ReClammPoolHelper(vault_) {}

    /// @notice External proxy for the internal `_checkInitializationPrices`.
    function checkInitializationPrices(
        uint256[] calldata balancesScaled18,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) external pure {
        _checkInitializationPrices(balancesScaled18, minPrice, maxPrice, targetPrice, virtualBalanceA, virtualBalanceB);
    }
}
