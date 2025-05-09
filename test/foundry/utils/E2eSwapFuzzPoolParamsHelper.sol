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
        uint256 minTradeAmount;
    }

    /**
     * @dev Generates fuzzed parameters for the pool.
     * Fuzz the minimum, maximum, target prices and real balances.
     * Virtual balances depend on actual balances, so both are fuzzed together to maintain internal consistency.
     */
    function _fuzzPoolParams(
        ReClammPoolMock pool,
        uint256[5] memory params,
        uint256 rateTokenA,
        uint256 rateTokenB,
        uint256 decimalsTokenA,
        uint256 decimalsTokenB
    ) internal returns (uint256 balanceA, uint256 balanceB) {
        TestParams memory testParams;
        testParams.rateTokenA = rateTokenA;
        testParams.rateTokenB = rateTokenB;
        testParams.decimalsTokenA = decimalsTokenA;
        testParams.decimalsTokenB = decimalsTokenB;
        testParams.initialBalances = new uint256[](2);

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
            // Both tokens must be kept below _MAX_TOKEN_BALANCE. The balance ratio can be anything, so we need
            // to cap the initialBalance[a] keeping in mind that initialBalance[b] also needs to be below the abs max.
            uint256 maxBalance = Math.min(_MAX_TOKEN_BALANCE.divDown(balanceRatio), _MAX_TOKEN_BALANCE.mulDown(balanceRatio));

            if (maxBalance < _MIN_TOKEN_BALANCE) {
                testParams.initialBalances[a] = _MIN_TOKEN_BALANCE;
            } else {
                testParams.initialBalances[a] = bound(
                    params[3],
                    _MIN_TOKEN_BALANCE,
                    maxBalance
                );
            }
            testParams.initialBalances[b] = testParams.initialBalances[a].mulDown(balanceRatio);

            console2.log('balance ratio: ', balanceRatio);

            // uint256 minDecimals = Math.min(decimalsTokenA, decimalsTokenB);
            // testParams.initialBalances[a] = _undoDecimals(testParams.initialBalances[a], minDecimals);
            // testParams.initialBalances[b] = _undoDecimals(testParams.initialBalances[b], minDecimals);
        }

        console.log('about to reinitialize');
        (uint256 virtualBalanceA, uint256 virtualBalanceB) = pool.reInitialize(
            testParams.initialBalances,
            testParams.minPrice,
            testParams.maxPrice,
            testParams.targetPrice,
            100e16, // 100%
            5e17
        );

        console2.log('about to compute centeredness');
        console2.log('initial balance A: ', testParams.initialBalances[a]);
        console2.log('initial balance B:', testParams.initialBalances[b]);
        uint256 currentCentredness = ReClammMath.computeCenteredness(
            testParams.initialBalances,
            virtualBalanceA,
            virtualBalanceB
        );

        vm.assume(currentCentredness >= 1e17);

        console.log('about to apply rate and scale');
        return (
            _applyRateAndScale(testParams.initialBalances[a], testParams.rateTokenA, testParams.decimalsTokenA),
            _applyRateAndScale(testParams.initialBalances[b], testParams.rateTokenB, testParams.decimalsTokenB)
        );
    }

    /**
     * @dev Calculates the minimum and maximum swap amounts for the given pool.
     * The function uses the current virtual balances and the initial balances to determine the swap limits.
     */
    function _calculateMinAndMaxSwapAmounts(
        IVaultMock vault,
        address pool,
        uint256 rateTokenA,
        uint256 rateTokenB,
        uint256 decimalsTokenA,
        uint256 decimalsTokenB,
        uint256 minTradeAmount
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
        testParams.minTradeAmount = minTradeAmount;

        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = ReClammPoolMock(pool)
            .computeCurrentVirtualBalances(balancesScaled18);

        console2.log('min trade amount: ', testParams.minTradeAmount);

        uint256 tokenAMinTradeAmountInExactOut = _applyRateAndScale(
            ReClammMath.computeInGivenOut(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                a,
                b,
                testParams.minTradeAmount
            ),
            testParams.rateTokenA,
            testParams.decimalsTokenA
        );
        uint256 tokenBMinTradeAmountOutExactIn = _applyRateAndScale(
            ReClammMath.computeOutGivenIn(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                a,
                b,
                testParams.minTradeAmount
            ),
            testParams.rateTokenB,
            testParams.decimalsTokenB
        );

        uint256 tokenAMinTradeAmountInExactIn = _applyRateAndScale(
            testParams.minTradeAmount,
            testParams.rateTokenA,
            testParams.decimalsTokenA
        );
        uint256 tokenBMinTradeAmountOutExactOut = _applyRateAndScale(
            testParams.minTradeAmount,
            testParams.rateTokenB,
            testParams.decimalsTokenB
        );

        // If the calculated minimum amount is less than the swap size, we use the minimum swap amount instead.
        minSwapAmountTokenA = tokenAMinTradeAmountInExactOut > tokenAMinTradeAmountInExactIn
            ? tokenAMinTradeAmountInExactOut
            : tokenAMinTradeAmountInExactIn;

        // We also multiply by 10 because there are some inaccuracies due to rounding in certain cases.
        minSwapAmountTokenA *= 10;

        // We do the same for tokenB
        minSwapAmountTokenB = tokenBMinTradeAmountOutExactIn > tokenBMinTradeAmountOutExactOut
            ? tokenBMinTradeAmountOutExactIn
            : tokenBMinTradeAmountOutExactOut;
        minSwapAmountTokenB *= 10;

        // Calculating the real maximum swap amount is quite difficult, so we estimate an approximate boundary.
        // Dividing by 5 was chosen experimentally, as there's no other way to determine this value.
        uint256[] memory balancesScaled18_ = balancesScaled18;

        console2.log('balance[a] scaled18: ', balancesScaled18_[a]);
        console2.log('balance[b] scaled18: ', balancesScaled18_[b]);

        // Divide by 5 to avoid PoolCenterednessTooLow
        maxSwapAmountTokenA = _applyRateAndScale(
            ReClammMath.computeInGivenOut(
                balancesScaled18_,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                a,
                b,
                balancesScaled18_[b]
            ),
            testParams.rateTokenA,
            testParams.decimalsTokenA
        );

        // Divide by 2 to avoid TokenBalanceTooLow
        maxSwapAmountTokenB = _applyRateAndScale(
            balancesScaled18_[b] / 100,
            testParams.rateTokenB,
            testParams.decimalsTokenB
        );

        console2.log('min swap amount A: ', minSwapAmountTokenA);
        console2.log('max swap amount A: ', maxSwapAmountTokenA);
    }

    function _applyRateAndScale(uint256 amount, uint256 rate, uint256 decimals) internal pure returns (uint256) {
        return amount.divUp(rate * (10 ** (18 - decimals)));
    }

    function _undoDecimals(uint256 amount, uint256 decimals) internal pure returns (uint256) {
        return amount / (10 ** (18 - decimals));
    }
}
