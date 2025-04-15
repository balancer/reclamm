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
import { ReClammMath, a, b } from "../../../contracts/lib/ReClammMath.sol";

contract E2eSwapFuzzPoolParamsHelper is Test, ReClammPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant MIN_BALANCE = 1_000 * FixedPoint.ONE;
    uint256 internal constant MAX_BALANCE = 100_000_000 * FixedPoint.ONE;
    uint256 internal constant MAX_PRICE = 100_000 * FixedPoint.ONE;
    uint256 internal constant MAX_PRICE_RATIO = 100;
    uint256 internal constant MAX_TIME_FOR_PRICE_CHANGE = 10 days;
    uint256 internal constant MIN_TIME_FOR_PRICE_CHANGE = 6 hours;
    uint256 internal constant TIME_BUFFER = 1 hours;

    struct TestParams {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 targetPrice;
        uint256 startTime;
        uint256 endTime;
        IVaultMock vault;
        IRouter router;
        address[] tokens;
        string label;
        address sender;
        uint256 centerednessMargin;
        uint256[] initialBalances;
    }

    function _fuzzPoolParams(
        uint256[5] memory params,
        IRouter router,
        IVaultMock vault,
        BasicAuthorizerMock authorizer,
        address[] memory tokens,
        string memory label,
        address sender
    ) internal returns (address pool, bytes memory poolArgs, uint256 balanceA, uint256 balanceB) {
        uint256 currentTime = block.timestamp;
        uint256 maxTime = currentTime + MAX_TIME_FOR_PRICE_CHANGE;

        balanceA = bound(params[0], MIN_BALANCE, MAX_BALANCE);

        TestParams memory testParams;
        testParams.vault = vault;
        testParams.router = router;
        testParams.tokens = tokens;
        testParams.label = label;
        testParams.sender = sender;

        testParams.maxPrice = bound(params[1], FixedPoint.ONE, MAX_PRICE);
        testParams.minPrice = bound(params[2], testParams.maxPrice / MAX_PRICE_RATIO, testParams.maxPrice - 1);
        testParams.targetPrice = bound(params[3], testParams.minPrice, testParams.maxPrice);

        {
            console.log("testParams.minPrice: ", testParams.minPrice);
            console.log("testParams.maxPrice: ", testParams.maxPrice);
            console.log("testParams.targetPrice: ", testParams.targetPrice);

            (
                uint256[] memory theoreticalRealBalances,
                uint256 theoreticalVirtualBalanceA,
                uint256 theoreticalVirtualBalanceB,

            ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
                    testParams.minPrice,
                    testParams.maxPrice,
                    testParams.targetPrice
                );

            console.log("Theoretical Real Balances A: ", theoreticalRealBalances[a]);
            console.log("Theoretical Real Balances B: ", theoreticalRealBalances[b]);
            console.log("Theoretical Virtual Balances A: ", theoreticalVirtualBalanceA);
            console.log("Theoretical Virtual Balances B: ", theoreticalVirtualBalanceB);

            testParams.initialBalances = new uint256[](2);
            uint256 balanceRatio = theoreticalRealBalances[b].divDown(theoreticalRealBalances[a]);
            testParams.initialBalances[a] = balanceA;
            balanceB = balanceA.mulDown(balanceRatio);
            testParams.initialBalances[b] = balanceB;

            console.log("Balance A: ", balanceA);
            console.log("Balance B: ", balanceB);

            uint256 scale = balanceA.divDown(theoreticalRealBalances[a]);
            uint256 virtualBalanceA = theoreticalVirtualBalanceA.mulDown(scale);
            uint256 virtualBalanceB = theoreticalVirtualBalanceB.mulDown(scale);
            testParams.centerednessMargin = ReClammMath.computeCenteredness(
                testParams.initialBalances,
                virtualBalanceA,
                virtualBalanceB
            );
        }

        vm.startPrank(testParams.sender);
        (pool, poolArgs) = createReClammPool(
            testParams.tokens,
            new IRateProvider[](0),
            testParams.label,
            testParams.vault,
            testParams.sender,
            testParams.minPrice,
            testParams.maxPrice,
            testParams.targetPrice,
            testParams.centerednessMargin
        );
        console.log("Pool created");

        testParams.router.initialize(
            pool,
            testParams.tokens.asIERC20(),
            testParams.initialBalances,
            0,
            false,
            bytes("")
        );
        console.log("Pool initialized");
        vm.stopPrank();
    }
}
