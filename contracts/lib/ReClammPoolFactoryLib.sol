// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IReClammPool, ReClammPoolParams } from "../interfaces/IReClammPool.sol";

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
    using FixedPoint for uint256;

    // Price ratio below 1 breaks pool math. Also, tight ratios close to FP(1) may cause virtual balances to grow
    // excessively, potentially causing numerical issues. In practice, such tight ratios should not be needed.
    // solhint-disable-next-line private-vars-leading-underscore
    uint256 internal constant MIN_PRICE_RATIO = 1.0001e18; // 0.01% above FP(1)

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

    function validatePriceParams(ReClammPoolParams memory params) internal pure {
        if (
            params.initialMinPrice == 0 ||
            params.initialMaxPrice == 0 ||
            params.initialTargetPrice == 0 ||
            params.initialTargetPrice < params.initialMinPrice ||
            params.initialTargetPrice > params.initialMaxPrice ||
            params.initialMinPrice >= params.initialMaxPrice
        ) {
            // If any of these prices were 0, pool initialization would revert with a numerical error.
            // For good measure, we also ensure the target is within the range.
            revert IReClammPool.InvalidInitialPrice();
        }

        uint256 initialPriceRatio = params.initialMaxPrice.divDown(params.initialMinPrice);
        if (initialPriceRatio < MIN_PRICE_RATIO) {
            revert IReClammPool.PriceRatioBelowMin(initialPriceRatio);
        }
    }
}
