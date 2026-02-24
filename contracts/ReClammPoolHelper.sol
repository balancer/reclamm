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
        IReClammPool pool,
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw) {
        IERC20[] memory tokens = vault.getPoolTokens(address(pool));

        (uint256 referenceTokenIdx, uint256 otherTokenIdx) = tokens[a] == referenceToken ? (a, b) : (b, a);

        if (referenceTokenIdx == b && referenceToken != tokens[b]) {
            revert IVaultErrors.InvalidToken();
        }

        (uint256 rateA, uint256 rateB) = vault.getTokenRates(address(pool));
        uint256 balanceRatioScaled18 = _computeInitialBalanceRatioScaled18(IReClammPool(pool), rateA, rateB);
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
        ReClammPoolImmutableData memory data = pool.getReClammPoolImmutableData();

        (uint256 minPriceScaled18, uint256 maxPriceScaled18, uint256 targetPriceScaled18) = ReClammHelperLib
            .getPriceSettingsAdjustedByRates(
                data.tokenAPriceIncludesRate,
                data.tokenBPriceIncludesRate,
                data.initialMinPrice,
                data.initialMaxPrice,
                data.initialTargetPrice,
                rateA,
                rateB
            );

        (uint256[] memory theoreticalBalancesScaled18, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            minPriceScaled18,
            maxPriceScaled18,
            targetPriceScaled18
        );

        return theoreticalBalancesScaled18[b].divDown(theoreticalBalancesScaled18[a]);
    }
}
