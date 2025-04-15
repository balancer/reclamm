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

    uint256 internal constant _MIN_TOKEN_BALANCE = 1e12;
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;
    uint256 internal constant _MIN_PRICE = 1e14; // 0.0001
    uint256 internal constant _MAX_PRICE = 1e24; // 1_000_000
    uint256 internal constant _MIN_PRICE_RATIO = 1.1e18;

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
        balanceA = bound(params[0], _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);

        TestParams memory testParams;
        testParams.vault = vault;
        testParams.router = router;
        testParams.tokens = tokens;
        testParams.label = label;
        testParams.sender = sender;

        testParams.minPrice = bound(params[0], _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        testParams.maxPrice = bound(params[1], testParams.minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        testParams.targetPrice = bound(
            params[2],
            testParams.minPrice + testParams.minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            testParams.maxPrice - testParams.minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        {
            uint256 _param3 = params[3];
            (
                uint256[] memory theoreticalRealBalances,
                uint256 theoreticalVirtualBalanceA,
                uint256 theoreticalVirtualBalanceB,

            ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
                    testParams.minPrice,
                    testParams.maxPrice,
                    testParams.targetPrice
                );

            testParams.initialBalances = new uint256[](2);
            uint256 balanceRatio = theoreticalRealBalances[b].divDown(theoreticalRealBalances[a]);
            balanceA = bound(_param3, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE.divDown(balanceRatio));
            testParams.initialBalances[a] = balanceA;
            balanceB = balanceA.mulDown(balanceRatio);
            testParams.initialBalances[b] = balanceB;

            uint256 scale = balanceA.divDown(theoreticalRealBalances[a]);
            uint256 virtualBalanceA = theoreticalVirtualBalanceA.mulDown(scale);
            uint256 virtualBalanceB = theoreticalVirtualBalanceB.mulDown(scale);
            testParams.centerednessMargin = 5e17; // 50%
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
