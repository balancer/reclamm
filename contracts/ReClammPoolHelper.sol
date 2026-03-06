// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPoolImmutableData, IReClammPool } from "./interfaces/IReClammPool.sol";
import { ReClammMath, a, b } from "./lib/ReClammMath.sol";

/// @notice Stateless helper contract to perform accessory computations for the `ReClammPool`.
contract ReClammPoolHelper {
    using FixedPoint for uint256;
    using ScalingHelpers for *;

    // This represents the maximum deviation from the ideal state (i.e., at target price and near centered) after
    // initialization, to prevent arbitration losses.
    uint256 public constant BALANCE_RATIO_AND_PRICE_TOLERANCE = 0.01e16; // 0.01%

    uint256 internal constant _MAX_TOKEN_DECIMALS = 18;

    // solhint-disable-next-line immutable-vars-naming
    IVault public immutable vault;

    constructor(IVault vault_) {
        vault = vault_;
    }

    function computeInitialBalancesRaw(
        IReClammPool pool,
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw) {
        IERC20[] memory tokens = vault.getPoolTokens(address(pool));

        (uint256 referenceTokenIdx, uint256 otherTokenIdx) = address(tokens[a]) == address(referenceToken)
            ? (a, b)
            : (b, a);

        if (referenceTokenIdx == b && address(referenceToken) != address(tokens[b])) {
            revert IVaultErrors.InvalidToken();
        }

        (uint256 rateA, uint256 rateB) = _getTokenRates(address(pool));
        uint256 balanceRatioScaled18 = _computeInitialBalanceRatioScaled18(IReClammPool(pool), rateA, rateB);
        (uint256 rateReferenceToken, uint256 rateOtherToken) = address(tokens[a]) == address(referenceToken)
            ? (rateA, rateB)
            : (rateB, rateA);

        uint8 decimalsReferenceToken = IERC20Metadata(address(tokens[referenceTokenIdx])).decimals();
        uint8 decimalsOtherToken = IERC20Metadata(address(tokens[otherTokenIdx])).decimals();

        uint256 referenceAmountInScaled18 = referenceAmountInRaw.toScaled18ApplyRateRoundDown(
            10 ** (_MAX_TOKEN_DECIMALS - decimalsReferenceToken),
            rateReferenceToken
        );

        // Since the ratio is defined as b/a, multiply if we're given a, and divide if we're given b.
        // If the theoretical virtual balances were a=50 and b=100, then the ratio would be 100/50 = 2.
        // If we're given 100 a tokens, b = a * 2 = 200. If we're given 200 b tokens, a = b / 2 = 100.
        initialBalancesRaw = new uint256[](2);
        initialBalancesRaw[referenceTokenIdx] = referenceAmountInRaw;

        function(uint256, uint256) pure returns (uint256) _mulOrDiv = referenceTokenIdx == a
            ? FixedPoint.mulDown
            : FixedPoint.divDown;
        initialBalancesRaw[otherTokenIdx] = _mulOrDiv(referenceAmountInScaled18, balanceRatioScaled18)
            .toRawUndoRateRoundDown(10 ** (_MAX_TOKEN_DECIMALS - decimalsOtherToken), rateOtherToken);
    }

    function computeInitialBalanceRatioScaled18(
        IReClammPool pool,
        uint256 rateA,
        uint256 rateB
    ) external view returns (uint256) {
        return _computeInitialBalanceRatioScaled18(pool, rateA, rateB);
    }

    function _computeInitialBalanceRatioScaled18(
        IReClammPool pool,
        uint256 rateA,
        uint256 rateB
    ) internal view returns (uint256) {
        (
            uint256 minPriceScaled18,
            uint256 maxPriceScaled18,
            uint256 targetPriceScaled18
        ) = _getPriceSettingsAdjustedByRates(pool, rateA, rateB);

        (uint256[] memory theoreticalBalancesScaled18, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            minPriceScaled18,
            maxPriceScaled18,
            targetPriceScaled18
        );

        return theoreticalBalancesScaled18[b].divDown(theoreticalBalancesScaled18[a]);
    }

    struct InitializeLocals {
        uint256 rateA;
        uint256 rateB;
        uint256 minPriceScaled18;
        uint256 maxPriceScaled18;
        uint256 targetPriceScaled18;
        uint256[] theoreticalBalances;
        uint256 theoreticalVirtualBalanceA;
        uint256 theoreticalVirtualBalanceB;
        uint256 priceRatio;
    }

    /**
     * @notice Compute the initialization amounts, given a reference token and amount.
     * @dev Must be called by the pool; this function should not be called directly.
     */
    function computeInitialVirtualBalancesAndRatio(
        uint256[] calldata balancesScaled18
    ) external view returns (uint256, uint256, uint256) {
        IReClammPool pool = IReClammPool(msg.sender);
        InitializeLocals memory locals;
        (locals.rateA, locals.rateB) = _getTokenRates(address(pool));

        (
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18
        ) = _getPriceSettingsAdjustedByRates(pool, locals.rateA, locals.rateB);

        (
            locals.theoreticalBalances,
            locals.theoreticalVirtualBalanceA,
            locals.theoreticalVirtualBalanceB,
            locals.priceRatio
        ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18
        );

        _checkInitializationBalanceRatio(balancesScaled18, locals.theoreticalBalances);

        uint256 scale = balancesScaled18[a].divDown(locals.theoreticalBalances[a]);

        uint256 virtualBalanceA = locals.theoreticalVirtualBalanceA.mulDown(scale);
        uint256 virtualBalanceB = locals.theoreticalVirtualBalanceB.mulDown(scale);

        _checkInitializationPrices(
            balancesScaled18,
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18,
            virtualBalanceA,
            virtualBalanceB
        );

        return (virtualBalanceA, virtualBalanceB, locals.priceRatio);
    }

    function getTokenRates(address pool) external view returns (uint256 rateA, uint256 rateB) {
        return _getTokenRates(pool);
    }

    function _getTokenRates(address pool) internal view returns (uint256 rateA, uint256 rateB) {
        (, TokenInfo[] memory tokenInfo, , ) = vault.getPoolTokenInfo(pool);

        rateA = _getTokenRate(tokenInfo[a]);
        rateB = _getTokenRate(tokenInfo[b]);
    }

    function _getTokenRate(TokenInfo memory tokenInfo) internal view returns (uint256) {
        return tokenInfo.tokenType == TokenType.WITH_RATE ? tokenInfo.rateProvider.getRate() : FixedPoint.ONE;
    }

    function _getPriceSettingsAdjustedByRates(
        IReClammPool pool,
        uint256 rateA,
        uint256 rateB
    ) internal view returns (uint256 minPrice, uint256 maxPrice, uint256 targetPrice) {
        ReClammPoolImmutableData memory data = pool.getReClammPoolImmutableData();

        rateA = data.tokenAPriceIncludesRate ? FixedPoint.ONE : rateA;
        rateB = data.tokenBPriceIncludesRate ? FixedPoint.ONE : rateB;

        // Example: a pool waUSDC/waWETH, where the price is given in terms of the underlying tokens.
        // Consider a USDC/ETH pool where the price is 2000. Token A is ETH (waWETH); token B is USDC (waUSDC).
        // If waUSDC has a rate of 2 (1 waUSDC = 2 USDC), the price of waUSDC/ETH is 1000, which is
        // obtained by dividing the price by the rate of waUSDC, which is token B.
        // Now, if the rate of waWETH is 1.5 (1 waWETH = 1.5 ETH), waUSDC/waWETH = 1500, which is
        // obtained by multiplying the price by the rate of waWETH, which is token A.
        // On the other hand, spot prices are computed using live balances which always contain the rates, so
        // we apply the inverse here (i.e. multiply by rate B, divide by rate A) to undo the effect.
        minPrice = (data.initialMinPrice * rateB) / rateA;
        maxPrice = (data.initialMaxPrice * rateB) / rateA;
        targetPrice = (data.initialTargetPrice * rateB) / rateA;
    }

    function checkInitializationBalanceRatio(
        uint256[] calldata balancesScaled18,
        uint256[] memory theoreticalBalances
    ) external pure {
        return _checkInitializationBalanceRatio(balancesScaled18, theoreticalBalances);
    }

    /// @dev Checks that the current balance ratio is within the initialization balance ratio tolerance.
    function _checkInitializationBalanceRatio(
        uint256[] calldata balancesScaled18,
        uint256[] memory theoreticalBalances
    ) internal pure {
        uint256 realBalanceRatio = balancesScaled18[b].divDown(balancesScaled18[a]);
        uint256 theoreticalBalanceRatio = theoreticalBalances[b].divDown(theoreticalBalances[a]);

        uint256 ratioLowerBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE - BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 ratioUpperBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE + BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (realBalanceRatio < ratioLowerBound || realBalanceRatio > ratioUpperBound) {
            revert IReClammPool.BalanceRatioExceedsTolerance();
        }
    }

    /**
     * @dev Checks that the current spot price is within the initialization tolerance of the price target, and that
     * the total price range after initialization (i.e., with real balances) corresponds closely enough to the desired
     * initial price range set on deployment.
     */
    function _checkInitializationPrices(
        uint256[] calldata balancesScaled18,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure {
        // Compare current spot price with initialization target price.
        uint256 spotPrice = (balancesScaled18[b] + virtualBalanceB).divDown(balancesScaled18[a] + virtualBalanceA);
        _comparePrice(spotPrice, targetPrice);

        uint256 currentInvariant = ReClammMath.computeInvariant(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB,
            Rounding.ROUND_DOWN
        );

        // Compare current min price with initialization min price.
        uint256 currentMinPrice = (virtualBalanceB * virtualBalanceB) / currentInvariant;
        _comparePrice(currentMinPrice, minPrice);

        // Compare current max price with initialization max price.
        uint256 currentMaxPrice = _computeMaxPrice(currentInvariant, virtualBalanceA);
        _comparePrice(currentMaxPrice, maxPrice);
    }

    function _comparePrice(uint256 currentPrice, uint256 initializationPrice) internal pure {
        uint256 priceLowerBound = initializationPrice.mulDown(FixedPoint.ONE - BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 priceUpperBound = initializationPrice.mulDown(FixedPoint.ONE + BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (currentPrice < priceLowerBound || currentPrice > priceUpperBound) {
            revert IReClammPool.WrongInitializationPrices();
        }
    }

    function _computeMaxPrice(uint256 currentInvariant, uint256 virtualBalanceA) internal pure returns (uint256) {
        return currentInvariant.divDown(virtualBalanceA.mulDown(virtualBalanceA));
    }

    /**
     * @notice Computes the current spot price of token B in terms of token A: i.e., how many token A units are
     * required to purchase one token B, or equivalently, how many token A units you receive per token B sold.
     * @dev The price is expressed as token/token (e.g., wstETH/USDC), not underlying/underlying (e.g. ETH/USDC).
     * This matches what a swapper experiences: if this function returns 3000, then swapping 3000 USDC yields
     * approximately 1 wstETH. Internally, the spot price is derived from live (rate-scaled) balances plus virtual
     * balances, then adjusted by the ratio of token rates (rateA / rateB) to convert from the underlying/underlying
     * price that the AMM math operates on to the token/token price that callers expect. For pools with no rate
     * providers (or rate = 1), the two are identical.
     *
     * Note that `initialTargetPrice` may have been specified in either token or underlying terms depending on
     * `tokenAPriceIncludesRate` / `tokenBPriceIncludesRate`, so it cannot in general be directly compared to this
     * return value.
     *
     * It is meant to be called off-chain. Given the nature of the internal pool math (particularly when virtual
     * balances are shifting), this function **cannot be used as a price oracle**.
     *
     * @param pool The address of the pool
     * @return currentSpotPrice Spot price at the current pool state (real and virtual balances), in token/token terms
     */
    function computeCurrentSpotPrice(address pool) external view returns (uint256) {
        (, uint256[] memory tokenRates) = vault.getPoolTokenRates(pool);
        uint256[] memory balancesScaled18 = vault.getCurrentLiveBalances(pool);
        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = IReClammPool(pool)
            .computeCurrentVirtualBalances();

        // Undo rate effects to return the spot price in terms of actual token amounts.
        return
            ((balancesScaled18[b] + currentVirtualBalanceB) * tokenRates[a]) /
            (balancesScaled18[a] + currentVirtualBalanceA).mulUp(tokenRates[b]);
    }
}
