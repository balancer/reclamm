// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { IReClammPool, ReClammPoolParams } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolFactoryLib, ReClammPriceParams } from "../../contracts/lib/ReClammPoolFactoryLib.sol";

contract ReClammPoolFactoryLibTest is Test {
    // Mirrors the library constants so expected values are visible at test sites.
    uint256 internal constant _MIN_PRICE_RATIO = 1.0001e18;
    uint256 internal constant _MAX_PRICE_RATIO = 20e18;
    uint256 internal constant _MAX_CENTEREDNESS_MARGIN = 90e16;
    uint256 internal constant _MAX_DAILY_PRICE_SHIFT_EXPONENT = 100e16;

    // Valid defaults used to build a passing `ReClammPoolParams` that individual tests then
    // mutate to exercise a specific branch.
    uint256 internal constant _VALID_MIN_PRICE = 1e18;
    uint256 internal constant _VALID_MAX_PRICE = 4e18;
    uint256 internal constant _VALID_TARGET_PRICE = 2e18;
    uint256 internal constant _VALID_DAILY_PRICE_SHIFT_EXPONENT = 50e16;
    uint64 internal constant _VALID_CENTEREDNESS_MARGIN = 20e16;

    // ETH/USDC pool defaults for validateTargetPrice tests.
    // Price of 1 ETH expressed in USDC (18-decimal fixed point).
    uint256 internal constant _ETH_USDC_MIN_PRICE = 1500e18;
    uint256 internal constant _ETH_USDC_MAX_PRICE = 3000e18;
    uint256 internal constant _ETH_USDC_TARGET_PRICE = 2000e18;

    /********************************************************
                                Helpers
    ********************************************************/

    function _buildParams() internal pure returns (ReClammPoolParams memory params) {
        params = ReClammPoolParams({
            name: "Test",
            symbol: "TEST",
            version: "v1",
            dailyPriceShiftExponent: _VALID_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: _VALID_CENTEREDNESS_MARGIN,
            initialMinPrice: _VALID_MIN_PRICE,
            initialMaxPrice: _VALID_MAX_PRICE,
            initialTargetPrice: _VALID_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });
    }

    function _buildPriceParams(
        bool tokenAPriceIncludesRate,
        bool tokenBPriceIncludesRate
    ) internal pure returns (ReClammPriceParams memory) {
        return
            ReClammPriceParams({
                initialMinPrice: _VALID_MIN_PRICE,
                initialMaxPrice: _VALID_MAX_PRICE,
                initialTargetPrice: _VALID_TARGET_PRICE,
                tokenAPriceIncludesRate: tokenAPriceIncludesRate,
                tokenBPriceIncludesRate: tokenBPriceIncludesRate
            });
    }

    function _buildTokens(TokenType typeA, TokenType typeB) internal pure returns (TokenConfig[] memory tokens) {
        tokens = new TokenConfig[](2);
        tokens[0].tokenType = typeA;
        tokens[1].tokenType = typeB;
    }

    function _buildEthUsdcParams() internal pure returns (ReClammPoolParams memory params) {
        params = ReClammPoolParams({
            name: "ETH-USDC",
            symbol: "ETH-USDC",
            version: "v1",
            dailyPriceShiftExponent: _VALID_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: _VALID_CENTEREDNESS_MARGIN,
            initialMinPrice: _ETH_USDC_MIN_PRICE,
            initialMaxPrice: _ETH_USDC_MAX_PRICE,
            initialTargetPrice: _ETH_USDC_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });
    }

    /********************************************************
                        validateTokenConfig
    ********************************************************/

    // Branch: `tokens.length > 2` — reverts with `MaxTokens`.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTooManyTokensReverts() public {
        TokenConfig[] memory tokens = new TokenConfig[](3);
        ReClammPriceParams memory priceParams = _buildPriceParams(false, false);

        vm.expectRevert(IVaultErrors.MaxTokens.selector);
        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Boundary: `tokens.length == 2` passes the length check.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigExactlyTwoTokensSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.STANDARD, TokenType.STANDARD);
        ReClammPriceParams memory priceParams = _buildPriceParams(false, false);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Branch: `tokenAPriceIncludesRate && tokens[0].tokenType != WITH_RATE` — both sides true.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenAStandardWithRateFlagReverts() public {
        TokenConfig[] memory tokens = _buildTokens(TokenType.STANDARD, TokenType.WITH_RATE);
        ReClammPriceParams memory priceParams = _buildPriceParams(true, false);

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Sub-condition: `tokenAPriceIncludesRate == false` short-circuits the token A check
    // even when `tokens[0]` is STANDARD.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenAStandardWithoutRateFlagSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.STANDARD, TokenType.STANDARD);
        ReClammPriceParams memory priceParams = _buildPriceParams(false, false);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Sub-condition: `tokens[0].tokenType == WITH_RATE` makes the right half of the AND false,
    // so no revert even when `tokenAPriceIncludesRate == true`.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenAWithRateFlagMatchingTypeSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.WITH_RATE, TokenType.STANDARD);
        ReClammPriceParams memory priceParams = _buildPriceParams(true, false);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Branch: `tokenBPriceIncludesRate && tokens[1].tokenType != WITH_RATE` — both sides true.
    // Token A is WITH_RATE here so the token A branch is not what's firing.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenBStandardWithRateFlagReverts() public {
        TokenConfig[] memory tokens = _buildTokens(TokenType.WITH_RATE, TokenType.STANDARD);
        ReClammPriceParams memory priceParams = _buildPriceParams(false, true);

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Sub-condition: `tokenBPriceIncludesRate == false` short-circuits the token B check
    // even when `tokens[1]` is STANDARD. Uses WITH_RATE for token A to isolate the B path.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenBStandardWithoutRateFlagSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.WITH_RATE, TokenType.STANDARD);
        ReClammPriceParams memory priceParams = _buildPriceParams(true, false);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Sub-condition: `tokens[1].tokenType == WITH_RATE` makes the right half of the AND false,
    // so no revert even when `tokenBPriceIncludesRate == true`.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigTokenBWithRateFlagMatchingTypeSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.STANDARD, TokenType.WITH_RATE);
        ReClammPriceParams memory priceParams = _buildPriceParams(false, true);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    // Success: every check passes with both tokens WITH_RATE and both flags true.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTokenConfigBothWithRateBothFlagsSucceeds() public pure {
        TokenConfig[] memory tokens = _buildTokens(TokenType.WITH_RATE, TokenType.WITH_RATE);
        ReClammPriceParams memory priceParams = _buildPriceParams(true, true);

        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);
    }

    /********************************************************
                        validatePoolParams
    ********************************************************/

    // Branch: `dailyPriceShiftExponent > MAX_DAILY_PRICE_SHIFT_EXPONENT`.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsDailyPriceShiftExponentTooHighReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.dailyPriceShiftExponent = _MAX_DAILY_PRICE_SHIFT_EXPONENT + 1;

        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooHigh.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `dailyPriceShiftExponent == MAX_DAILY_PRICE_SHIFT_EXPONENT` is allowed (strict `>`).
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsDailyPriceShiftExponentAtMaxSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.dailyPriceShiftExponent = _MAX_DAILY_PRICE_SHIFT_EXPONENT;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `dailyPriceShiftExponent == 0` is allowed — there is no minimum.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsDailyPriceShiftExponentZeroSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.dailyPriceShiftExponent = 0;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Branch: `centerednessMargin > MAX_CENTEREDNESS_MARGIN`.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsCenterednessMarginTooHighReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.centerednessMargin = uint64(_MAX_CENTEREDNESS_MARGIN + 1);

        vm.expectRevert(IReClammPool.InvalidCenterednessMargin.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `centerednessMargin == MAX_CENTEREDNESS_MARGIN` is allowed (strict `>`).
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsCenterednessMarginAtMaxSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.centerednessMargin = uint64(_MAX_CENTEREDNESS_MARGIN);

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `centerednessMargin == 0` is allowed — there is no minimum.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsCenterednessMarginZeroSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.centerednessMargin = 0;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialMinPrice == 0`. Isolated — with max/target unchanged, no other
    // sub-condition in the OR fires (target is not < 0, target is not >= 4e18, min is not >= max).
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsInitialMinPriceZeroReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 0;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialMaxPrice == 0`. `max == 0` is the second sub-condition in the OR
    // and short-circuits before the subsequent `target >= max` / `min >= max` sub-conditions
    // that would also be true.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsInitialMaxPriceZeroReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMaxPrice = 0;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialTargetPrice == 0`. This is the third sub-condition in the OR and
    // short-circuits before `target < min` would also be true.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsInitialTargetPriceZeroReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialTargetPrice = 0;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialTargetPrice < initialMinPrice`. Isolated — min/max are non-zero,
    // target is within (0, max) and min < max, so only this sub-condition fires.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsTargetBelowMinReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 2e18;
        params.initialMaxPrice = 3e18;
        params.initialTargetPrice = 1e18;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialTargetPrice >= initialMaxPrice` — equality case. Isolated —
    // min < max and target >= min, so only this sub-condition fires.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsTargetEqualsMaxReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = 2e18;
        params.initialTargetPrice = 2e18;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialTargetPrice >= initialMaxPrice` — strictly greater case. Isolated —
    // min < max and target >= min, so only this sub-condition fires.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsTargetAboveMaxReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = 2e18;
        params.initialTargetPrice = 3e18;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialMinPrice >= initialMaxPrice` — equality case. `min == max` forces
    // either `target < min` or `target >= max` to also be true (no valid `target` exists
    // in an empty interval); the revert reason is the same for every sub-condition.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsMinEqualsMaxReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 2e18;
        params.initialMaxPrice = 2e18;
        params.initialTargetPrice = 2e18;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Sub-condition: `initialMinPrice >= initialMaxPrice` — strictly greater case. Same note as
    // the equality case: `min > max` also makes `target < min` or `target >= max` true.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsMinGreaterThanMaxReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 3e18;
        params.initialMaxPrice = 2e18;
        params.initialTargetPrice = 2.5e18;

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Branch: `initialPriceRatio < MIN_PRICE_RATIO`. With min = 1e18 and max = 1e18 + 1e10, the
    // ratio ≈ 1 + 1e-8, well below the 1.0001 floor. The target is centered so that
    // `validateTargetPrice` passes before the price-ratio check is reached.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsPriceRatioBelowMinReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = 1e18 + 1e10;
        params.initialTargetPrice = 1e18 + 5e9;
        params.centerednessMargin = 0;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioBelowMin.selector, uint256(1e18 + 1e10)));
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `initialPriceRatio == MIN_PRICE_RATIO` is allowed (strict `<`).
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsPriceRatioAtMinSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = _MIN_PRICE_RATIO; // 1.0001e18
        params.initialTargetPrice = 1.00005e18;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Branch: `initialPriceRatio > MAX_PRICE_RATIO`. With min = 1e18 and max = 21e18 the ratio
    // equals 21e18, one FP unit above the 20e18 cap.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsPriceRatioAboveMaxReverts() public {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = 21e18;
        params.initialTargetPrice = 10e18;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioAboveMax.selector, uint256(21e18)));
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Boundary: `initialPriceRatio == MAX_PRICE_RATIO` is allowed (strict `>`).
    // Centeredness margin is set to 0 to isolate the price-ratio boundary check.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsPriceRatioAtMaxSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        params.initialMinPrice = 1e18;
        params.initialMaxPrice = 20e18;
        params.initialTargetPrice = 10e18;
        params.centerednessMargin = 0;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Success: the default params pass every check.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidatePoolParamsAllValidSucceeds() public pure {
        ReClammPoolParams memory params = _buildParams();
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    /********************************************************
                        validateTargetPrice

        Prices are expressed as ETH/USDC (18 decimals).
        Default range: min = 1500, max = 3000, target = 2000.
        Price ratio = 2 (within [1.0001, 20]).
    ********************************************************/

    // --- Happy-path ---

    // Default ETH/USDC pool: target = 2000, range [1500, 3000], margin = 20%.
    // Centeredness ≈ 68.8%, well above the 20% margin.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceCenteredTargetSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target at the geometric mean (sqrt(1500 * 3000) ≈ 2121 USDC) is perfectly centered.
    // Centeredness ≈ 100%, passes even with the maximum allowed margin (90%).
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceGeometricMeanHighMarginSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 2121e18;
        params.centerednessMargin = uint64(_MAX_CENTEREDNESS_MARGIN); // 90%

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Slightly skewed toward max (target = 2500), but centeredness ≈ 32.8% is above the 20% margin.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceModeratelySkewedSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 2500e18;

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target = 2000 with a 60% margin. Centeredness ≈ 68.8% clears the bar.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceHighMarginSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.centerednessMargin = 60e16; // 60%

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target just above min (1501 USDC) with zero margin: any positive centeredness passes.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetNearMinZeroMarginSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 1501e18;
        params.centerednessMargin = 0.001e16; // 0.001%

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target just below max (2999 USDC) with zero margin: any positive centeredness passes.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetNearMaxZeroMarginSucceeds() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 2999e18;
        params.centerednessMargin = 0.001e16; // 0.001%

        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Always ok with 0 margin
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetAtEdgeZeroMargin() public pure {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = _ETH_USDC_MIN_PRICE;
        params.centerednessMargin = 0;

        ReClammPoolFactoryLib.validatePoolParams(params);

        params.initialTargetPrice = _ETH_USDC_MAX_PRICE - 1;
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // --- Revert: numerator / denominator zero ---

    // Target = min + 1 wei. Integer sqrt rounds sqrtTarget to sqrtMin, so numerator still = 0.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetOneWeiAboveMinReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = _ETH_USDC_MIN_PRICE + 1;
        params.centerednessMargin = 1;

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);

        // Target = max − 1 wei. Integer sqrt rounds sqrtTarget to sqrtMax, so denominator = 0.
        params.initialTargetPrice = _ETH_USDC_MAX_PRICE - 1;
        params.centerednessMargin = 1;

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // --- Revert: centeredness below margin ---

    // Target near min (1501 USDC), centeredness ≈ 0.08%. Even a 1% margin rejects it.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetNearMinWithMarginReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 1501e18;
        params.centerednessMargin = 1e16; // 1%

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target near max (2999 USDC), centeredness ≈ 0.04%. Even a 1% margin rejects it.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceTargetNearMaxWithMarginReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 2999e18;
        params.centerednessMargin = 1e16; // 1%

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Heavily skewed toward max (target = 2800), centeredness ≈ 9.6%, below the 20% margin.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceHeavilySkewedTowardMaxReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 2800e18;

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Heavily skewed toward min (target = 1600), centeredness ≈ 8.9%, below the 20% margin.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceHeavilySkewedTowardMinReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.initialTargetPrice = 1600e18;

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }

    // Target = 2000 with a 70% margin. Centeredness ≈ 68.8% is just below the bar.
    /// forge-config: default.allow_internal_expect_revert = true
    function testValidateTargetPriceMarginExceedsCenterednessReverts() public {
        ReClammPoolParams memory params = _buildEthUsdcParams();
        params.centerednessMargin = 70e16; // 70%

        vm.expectRevert(IReClammPool.InvalidInitialTargetPrice.selector);
        ReClammPoolFactoryLib.validatePoolParams(params);
    }
}
