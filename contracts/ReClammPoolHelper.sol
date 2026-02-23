// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";

import { ReClammPoolImmutableData, IReClammPool } from "./interfaces/IReClammPool.sol";
import { ReClammHelperLib } from "./lib/ReClammHelperLib.sol";
import { ReClammMath, a, b } from "./lib/ReClammMath.sol";

contract ReClammPoolHelper {
    using FixedPoint for uint256;
    using ReClammHelperLib for IVault;
    using ScalingHelpers for *;

    uint256 internal constant _MAX_TOKEN_DECIMALS = 18;

    IVault public immutable vault;

    constructor(IVault vault_) {
        vault = vault_;
    }

    function computeInitialBalancesRaw(
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw) {
        IERC20[] memory tokens = vault.getPoolTokens(msg.sender);

        (uint256 referenceTokenIdx, uint256 otherTokenIdx) = tokens[a] == referenceToken ? (a, b) : (b, a);

        if (referenceTokenIdx == b && referenceToken != tokens[b]) {
            revert IVaultErrors.InvalidToken();
        }

        (uint256 rateA, uint256 rateB) = vault.getTokenRates(msg.sender);
        uint256 balanceRatioScaled18 = _computeInitialBalanceRatioScaled18(IReClammPool(msg.sender), rateA, rateB);
        (uint256 rateReferenceToken, uint256 rateOtherToken) = tokens[a] == referenceToken
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
}
