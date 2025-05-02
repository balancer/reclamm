// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { BasicAuthorizerMock } from "@balancer-labs/v3-vault/contracts/test/BasicAuthorizerMock.sol";
import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";

import { BaseReClammTest } from "./BaseReClammTest.sol";
import { ReClammPoolContractsDeployer } from "./ReClammPoolContractsDeployer.sol";
import { ReClammPool } from "../../../contracts/ReClammPool.sol";
import { ReClammPoolMock } from "../../../contracts/test/ReClammPoolMock.sol";
import { ReClammMath, a, b } from "../../../contracts/lib/ReClammMath.sol";

contract E2eSwapFuzzPoolParamsHelper is Test, ReClammPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant _MIN_TOKEN_BALANCE = 1e18;
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;
    uint256 internal constant _MIN_PRICE = 1e14; // 0.0001
    uint256 internal constant _MAX_PRICE = 1e24; // 1_000_000
    uint256 internal constant _MIN_PRICE_RATIO = 1.1e18;

    struct TestParams {
        uint256[] initialBalances;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 targetPrice;
        uint256 rateTokenA;
        uint256 rateTokenB;
        uint256 decimalsTokenA;
        uint256 decimalsTokenB;
        uint256 mintTradeAmount;
    }

    function _fuzzPoolParams(
        ReClammPoolMock pool,
        uint256[5] memory params
    ) internal returns (uint256 balanceA, uint256 balanceB) {
        TestParams memory testParams;
        testParams.initialBalances = new uint256[](2);
        testParams.initialBalances[a] = bound(params[0], _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        testParams.minPrice = bound(params[0], _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        testParams.maxPrice = bound(params[1], testParams.minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        testParams.targetPrice = bound(
            params[2],
            testParams.minPrice + testParams.minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            testParams.maxPrice - testParams.minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        {
            (uint256[] memory theoreticalRealBalances, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
                testParams.minPrice,
                testParams.maxPrice,
                testParams.targetPrice
            );

            uint256 balanceRatio = theoreticalRealBalances[b].divDown(theoreticalRealBalances[a]);
            uint256 maxBalance = _MAX_TOKEN_BALANCE.divDown(balanceRatio);

            if (maxBalance < _MIN_TOKEN_BALANCE) {
                testParams.initialBalances[a] = _MIN_TOKEN_BALANCE;
            } else {
                testParams.initialBalances[a] = bound(
                    params[3],
                    _MIN_TOKEN_BALANCE,
                    _MAX_TOKEN_BALANCE.divDown(balanceRatio)
                );
            }
            testParams.initialBalances[b] = testParams.initialBalances[b] = testParams.initialBalances[a].mulDown(
                balanceRatio
            );
        }

        pool.reInitialize(
            testParams.initialBalances,
            testParams.minPrice,
            testParams.maxPrice,
            testParams.targetPrice,
            100e16, // 100%
            5e17
        );

        return (testParams.initialBalances[a], testParams.initialBalances[b]);
    }

    function _calculateMinAndMaxSwapAmounts(
        IVaultMock vault,
        address pool,
        uint256 rateTokenA,
        uint256 rateTokenB,
        uint256 decimalsTokenA,
        uint256 decimalsTokenB,
        uint256 mintTradeAmount
    )
        internal
        view
        returns (
            uint256 minSwapAmountTokenA,
            uint256 minSwapAmountTokenB,
            uint256 maxSwapAmountTokenA,
            uint256 maxSwapAmountTokenB
        )
    {
        TestParams memory testParams;
        testParams.rateTokenA = rateTokenA;
        testParams.rateTokenB = rateTokenB;
        testParams.decimalsTokenA = decimalsTokenA;
        testParams.decimalsTokenB = decimalsTokenB;
        testParams.mintTradeAmount = mintTradeAmount;

        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);
        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = ReClammPoolMock(pool)
            .computeCurrentVirtualBalances(balancesScaled18);

        uint256 tokenAMinTradeAmountInExactOut = ReClammMath
            .computeInGivenOut(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                a,
                b,
                testParams.mintTradeAmount
            )
            .divDown(testParams.rateTokenA)
            .mulDown(10 ** testParams.decimalsTokenA);
        uint256 tokenBMinTradeAmountOutExactIn = ReClammMath
            .computeOutGivenIn(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                a,
                b,
                testParams.mintTradeAmount
            )
            .divDown(testParams.rateTokenB)
            .mulDown(10 ** testParams.decimalsTokenB);

        uint256 tokenAMinTradeAmountInExactIn = testParams.mintTradeAmount.divUp(testParams.rateTokenA).mulUp(
            10 ** testParams.decimalsTokenA
        );
        uint256 tokenBMinTradeAmountOutExactOut = testParams.mintTradeAmount.divUp(testParams.rateTokenB).mulUp(
            10 ** testParams.decimalsTokenB
        );

        minSwapAmountTokenA = tokenAMinTradeAmountInExactOut > tokenAMinTradeAmountInExactIn
            ? tokenAMinTradeAmountInExactOut
            : tokenAMinTradeAmountInExactIn;
        minSwapAmountTokenA *= 10;

        minSwapAmountTokenB = tokenBMinTradeAmountOutExactIn > tokenBMinTradeAmountOutExactOut
            ? tokenBMinTradeAmountOutExactIn
            : tokenBMinTradeAmountOutExactOut;
        minSwapAmountTokenB *= 10;

        uint256[] memory balancesScaled18_ = balancesScaled18;
        maxSwapAmountTokenA = (ReClammMath.computeInGivenOut(
            balancesScaled18_,
            currentVirtualBalanceA,
            currentVirtualBalanceB,
            a,
            b,
            balancesScaled18_[b]
        ) / 5).mulDown(10 ** (testParams.decimalsTokenA)).divDown(testParams.rateTokenA); // Divide by 5 to avoid PoolCenterednessTooLow

        maxSwapAmountTokenB = (balancesScaled18_[b] / 2).mulDown(10 ** (testParams.decimalsTokenB)).divDown(
            testParams.rateTokenB
        ); // Divide by 2 to avoid TokenBalanceTooLow
    }
}
