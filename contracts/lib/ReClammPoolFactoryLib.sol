// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

/**
 * @notice ReClammPool initialization parameters.
 * @dev ReClamm pools may contain wrapped tokens (with rate providers), in which case there are two options for
 * providing the initialization prices (and the initialization balances can be calculated in terms of either
 * token). If the price is that of the wrapped token, we should not apply the rate, so the flag for that token
 * should be false. If the price is given in terms of the underlying, we do need to apply the rate when computing
 * the initialization balances.
 *
 * @param initialMinPrice The initial minimum price of token A in terms of token B as an 18-decimal FP value
 * @param initialMaxPrice The initial maximum price of token A in terms of token B as an 18-decimal FP value
 * @param initialTargetPrice The initial target price of token A in terms of token B as an 18-decimal FP value
 * @param tokenAPriceIncludesRate Whether the amount of token A is scaled by the rate when calculating the price
 * @param tokenBPriceIncludesRate Whether the amount of token B is scaled by the rate when calculating the price
 */
struct ReClammPriceParams {
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

library ReClammPoolFactoryLib {
    function validateTokenConfig(TokenConfig[] memory tokens, ReClammPriceParams memory priceParams) internal pure {
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
    }
}
