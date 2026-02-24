// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPoolImmutableData, IReClammPool } from "../interfaces/IReClammPool.sol";
import { a, b } from "./ReClammMath.sol";

/// @dev Helper library with common functionality for ReClammPool and ReClammPoolHelper.
library ReClammHelperLib {
    function getTokenRates(IVault vault, address pool) internal view returns (uint256 rateA, uint256 rateB) {
        (, TokenInfo[] memory tokenInfo, , ) = vault.getPoolTokenInfo(pool);

        rateA = _getTokenRate(tokenInfo[a]);
        rateB = _getTokenRate(tokenInfo[b]);
    }

    function _getTokenRate(TokenInfo memory tokenInfo) internal view returns (uint256) {
        return tokenInfo.tokenType == TokenType.WITH_RATE ? tokenInfo.rateProvider.getRate() : FixedPoint.ONE;
    }

    function getPriceSettingsAdjustedByRates(
        bool tokenAPriceIncludesRate,
        bool tokenBPriceIncludesRate,
        uint256 initialMinPrice,
        uint256 initialMaxPrice,
        uint256 initialTargetPrice,
        uint256 rateA,
        uint256 rateB
    ) internal pure returns (uint256 minPrice, uint256 maxPrice, uint256 targetPrice) {
        rateA = tokenAPriceIncludesRate ? FixedPoint.ONE : rateA;
        rateB = tokenBPriceIncludesRate ? FixedPoint.ONE : rateB;

        // Example: a pool waUSDC/waWETH, where the price is given in terms of the underlying tokens.
        // Consider a USDC/ETH pool where the price is 2000. Token A is ETH (waWETH); token B is USDC (waUSDC).
        // If waUSDC has a rate of 2 (1 waUSDC = 2 USDC), the price of waUSDC/ETH is 1000, which is
        // obtained by dividing the price by the rate of waUSDC, which is token B.
        // Now, if the rate of waWETH is 1.5 (1 waWETH = 1.5 ETH), waUSDC/waWETH = 1500, which is
        // obtained by multiplying the price by the rate of waWETH, which is token A.
        // On the other hand, spot prices are computed using live balances which always contain the rates, so
        // we apply the inverse here (i.e. multiply by rate B, divide by rate A) to undo the effect.
        minPrice = (initialMinPrice * rateB) / rateA;
        maxPrice = (initialMaxPrice * rateB) / rateA;
        targetPrice = (initialTargetPrice * rateB) / rateA;
    }
}
