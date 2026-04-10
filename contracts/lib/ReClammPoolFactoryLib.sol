// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IReClammPool, ReClammPoolParams } from "../interfaces/IReClammPool.sol";
import { ReClammMath } from "./ReClammMath.sol";

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

    // solhint-disable private-vars-leading-underscore

    // Price ratio below 1 breaks pool math. Also, tight ratios close to FP(1) may cause virtual balances to grow
    // excessively, potentially causing numerical issues. In practice, such tight ratios should not be needed.
    // Minimum allowed price ratio (max price / min price). Price ratios below 1 break pool math; ratios very close
    // to 1 cause virtual balances to grow extremely large (Va ~= Ra / (sqrt(Q) - 1)), which risks numerical overflow
    // in downstream calculations. 0.01% above FP(1) provides a practical lower bound while still supporting
    // tightly-pegged stable pairs.
    uint256 internal constant MIN_PRICE_RATIO = 1.0001e18; // 0.01% above FP(1)

    // Maximum allowed price ratio (max price / min price). At Q = 20, the pool still provides meaningful capital
    // efficiency (~1.9x vs a standard constant-product AMM). This is set just above the highest price ratio observed
    // for realistic token pairs. For example, the ETH/BTC all-time range is ~9.2x, and stablecoin de-pegs (excluding
    // catastrophic collapses like UST) have peaked at ~1.2x. A cap of 20 prevents pools from operating in regimes
    // where the concentrated liquidity benefit is marginal and the virtual balance math is under stress, without
    // restricting any legitimate deployment.
    uint256 internal constant MAX_PRICE_RATIO = 20e18; // FP(20)

    // Maximum centeredness margin. The margin defines a sub-range of the total price range; the pool is "in target
    // range" only when its centeredness meets or exceeds this threshold. At 100%, the pool would always have to be
    // exactly centered, which is impossible since any swap moves it. Capping at 90% leaves a thin but non-zero working
    // margin, while still allowing operators who want very tight in-range definitions.
    uint256 internal constant MAX_CENTEREDNESS_MARGIN = 90e16; // 90%

    // The daily price shift exponent is a percentage that defines the speed at which the virtual balances will change
    // over the course of one day. A value of 100% (i.e, FP 1) means the min and max prices will double (or halve)
    // every day, until the pool price is within the range defined by the margin. This constant defines the maximum
    // "price shift" velocity.
    uint256 internal constant MAX_DAILY_PRICE_SHIFT_EXPONENT = 100e16; // 100%

    // solhint-enable private-vars-leading-underscore

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

    function validatePoolParams(ReClammPoolParams memory params) internal pure {
        // Note that there is no minimum for the daily price shift exponent, as a value of 0 (no price shift) is a
        // valid configuration.
        if (params.dailyPriceShiftExponent > MAX_DAILY_PRICE_SHIFT_EXPONENT) {
            revert IReClammPool.DailyPriceShiftExponentTooHigh();
        }

        // Likewise, there is no minimum for the centeredness margin. A value of 0 is a valid configuration: the
        // target range becomes the full price range, so the pool is always considered in range.
        if (params.centerednessMargin > MAX_CENTEREDNESS_MARGIN) {
            revert IReClammPool.InvalidCenterednessMargin();
        }

        if (
            params.initialMinPrice == 0 ||
            params.initialMaxPrice == 0 ||
            params.initialTargetPrice == 0 ||
            params.initialTargetPrice < params.initialMinPrice ||
            params.initialTargetPrice >= params.initialMaxPrice ||
            params.initialMinPrice >= params.initialMaxPrice
        ) {
            // If any of these prices were 0, pool initialization would revert with a numerical error.
            // For good measure, we also ensure the target is within the range.
            revert IReClammPool.InvalidInitialPrice();
        }

        validateTargetPrice(params);

        uint256 initialPriceRatio = params.initialMaxPrice.divDown(params.initialMinPrice);

        if (initialPriceRatio < MIN_PRICE_RATIO) {
            revert IReClammPool.PriceRatioBelowMin(initialPriceRatio);
        } else if (initialPriceRatio > MAX_PRICE_RATIO) {
            revert IReClammPool.PriceRatioAboveMax(initialPriceRatio);
        }
    }

    /// @notice Reverts if initial target price is outside the target range defined by the centeredness margin.
    function validateTargetPrice(ReClammPoolParams memory params) internal pure {
        if (params.centerednessMargin == 0) {
            // With a 0 margin, any target price within the min-max range is valid; return early.
            return;
        }

        uint256 sqrtMinPrice = ReClammMath.sqrtScaled18(params.initialMinPrice);
        uint256 sqrtMaxPrice = ReClammMath.sqrtScaled18(params.initialMaxPrice);
        uint256 sqrtTargetPrice = ReClammMath.sqrtScaled18(params.initialTargetPrice);

        uint256 numerator = sqrtTargetPrice.mulDown(sqrtTargetPrice - sqrtMinPrice);
        uint256 denominator = sqrtMinPrice.mulDown(sqrtMaxPrice - sqrtTargetPrice);

        if (numerator == 0 || denominator == 0) {
            // This does not make sense; the pool is out of range regardless the centeredness margin.
            revert IReClammPool.InvalidInitialTargetPrice();
        }

        uint256 x1 = numerator.divDown(denominator);
        uint256 x2 = denominator.divDown(numerator);
        uint256 centeredness = Math.min(x1, x2);

        if (centeredness < params.centerednessMargin) {
            revert IReClammPool.InvalidInitialTargetPrice();
        }
    }
}
