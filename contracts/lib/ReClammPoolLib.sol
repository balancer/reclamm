// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { ReClammPriceParams } from "../interfaces/IReClammPool.sol";
import { IReClammErrors } from "../interfaces/IReClammErrors.sol";

library ReClammPoolLib {
    function validateTokenAndPriceConfig(
        TokenConfig[] memory tokens,
        ReClammPriceParams memory priceParams
    ) internal pure {
        // The ReClammPool only supports 2 tokens.
        if (tokens.length > 2) {
            revert IVaultErrors.MaxTokens();
        }

        if (priceParams.tokenAPriceIncludesRate && tokens[0].tokenType != TokenType.WITH_RATE) {
            revert IVaultErrors.InvalidTokenType();
        }
        if (priceParams.tokenBPriceIncludesRate && tokens[1].tokenType != TokenType.WITH_RATE) {
            revert IVaultErrors.InvalidTokenType();
        }

        validatePriceConfig(priceParams);
    }

    function validatePriceConfig(ReClammPriceParams memory priceParams) internal pure {
        if (
            priceParams.initialMinPrice == 0 ||
            priceParams.initialMaxPrice == 0 ||
            priceParams.initialTargetPrice == 0 ||
            priceParams.initialTargetPrice < priceParams.initialMinPrice ||
            priceParams.initialTargetPrice > priceParams.initialMaxPrice ||
            priceParams.initialMinPrice >= priceParams.initialMaxPrice
        ) {
            // If any of these prices were 0, pool initialization would revert with a numerical error.
            // For good measure, we also ensure the target is within the range. The immutable variables must be
            // initialized in both the main and extension contracts, but validation is only done here.
            revert IReClammErrors.InvalidInitialPrice();
        }
    }
}
