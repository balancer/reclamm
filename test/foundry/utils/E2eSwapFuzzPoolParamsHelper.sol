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
import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";

import { ReClammPool } from "../../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./BaseReClammTest.sol";
import { ReClammPoolContractsDeployer } from "./ReClammPoolContractsDeployer.sol";

contract E2eSwapFuzzPoolParamsHelper is Test, ReClammPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant MAX_BALANCE = 1_000_000_000_000_000 * FixedPoint.ONE;
    uint256 internal constant MIN_PRICE_RATIO = FixedPoint.ONE + 1;
    uint256 internal constant MAX_PRICE_RATIO = 1_000_000_000 * FixedPoint.ONE;
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
    }

    function _fuzzPoolParams(
        uint256[7] memory params,
        IRouter router,
        IVaultMock vault,
        address[] memory tokens,
        string memory label,
        address sender
    ) internal returns (address pool, bytes memory poolArgs, uint256 balanceA, uint256 balanceB) {
        uint256 currentTime = block.timestamp;
        uint256 maxTime = currentTime + MAX_TIME_FOR_PRICE_CHANGE;

        balanceA = bound(params[0], FixedPoint.ONE, MAX_BALANCE);

        TestParams memory testParams;
        testParams.vault = vault;
        testParams.router = router;
        testParams.tokens = tokens;
        testParams.label = label;
        testParams.sender = sender;

        testParams.minPrice = bound(params[1], FixedPoint.ONE, MAX_BALANCE - 1);
        testParams.maxPrice = bound(params[2], testParams.minPrice + 1, MAX_BALANCE);
        testParams.targetPrice = bound(params[3], testParams.minPrice, testParams.maxPrice);

        testParams.startTime = bound(params[4], currentTime, maxTime);
        testParams.endTime = bound(params[5], testParams.startTime, maxTime);
        uint256 mockCurrentTime = bound(params[6], testParams.startTime, testParams.endTime + TIME_BUFFER);
        vm.warp(mockCurrentTime);

        uint256 priceRatio = testParams.maxPrice.divDown(testParams.minPrice);
        uint96 endFourthRootPriceRatio = SafeCast.toUint96(
            Math.sqrt(Math.sqrt(priceRatio * FixedPoint.ONE) * FixedPoint.ONE)
        );

        vm.startPrank(testParams.sender);
        IRateProvider[] memory rateProviders = new IRateProvider[](0);
        (pool, poolArgs) = createReClammPool(
            tokens,
            rateProviders,
            testParams.label,
            testParams.vault,
            testParams.sender,
            testParams.minPrice,
            testParams.maxPrice,
            testParams.targetPrice
        );

        uint256 balanceRatio = ReClammPool(pool).computeInitialBalanceRatio();

        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[0] = balanceA;
        balanceB = balanceA.mulDown(balanceRatio);
        initialBalances[1] = balanceB;

        testParams.router.initialize(pool, testParams.tokens.asIERC20(), initialBalances, 0, false, bytes(""));

        ReClammPool(pool).setPriceRatioState(endFourthRootPriceRatio, testParams.startTime, testParams.endTime);
        vm.stopPrank();
    }
}
