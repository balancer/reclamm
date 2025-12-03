// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { PoolConfigLib } from "@balancer-labs/v3-vault/contracts/lib/PoolConfigLib.sol";
import { E2eSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

contract E2eSwapReClammTest is E2eSwapFuzzPoolParamsHelper, E2eSwapTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Indicates whether to use fuzzed pool parameters. If false, standard calculateMinAndMaxSwapAmounts is used,
    // as not all tests inside E2ESwap utilize fuzzPoolParams.
    bool isFuzzPoolParams;

    function setUp() public override {
        setDefaultAccountBalance(type(uint128).max);
        super.setUp();

        exactInOutDecimalsErrorMultiplier = 2e9;
        amountInExactInOutError = 9e12;
    }

    function setUpVariables() internal override {
        sender = lp;
        poolCreator = lp;
    }

    function createPoolFactory() internal override returns (address) {
        return address(deployReClammPoolFactoryWithDefaultParams(vault));
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        return createReClammPool(tokens, label, vault, lp);
    }

    function fuzzPoolParams(
        uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params
    ) internal override returns (bool overrideSwapLimits) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        (poolInitAmountTokenA, poolInitAmountTokenB) = _fuzzPoolParams(
            ReClammPoolMock(payable(pool)),
            params,
            getRate(tokenA),
            getRate(tokenB),
            decimalsTokenA,
            decimalsTokenB
        );

        _donateToVault();

        isFuzzPoolParams = true;

        setPoolBalances(poolInitAmountTokenA, poolInitAmountTokenB);
        calculateMinAndMaxSwapAmounts();

        return true;
    }

    function calculateMinAndMaxSwapAmounts() internal override {
        if (isFuzzPoolParams == false) {
            super.calculateMinAndMaxSwapAmounts();
        } else {
            (
                minSwapAmountTokenA,
                minSwapAmountTokenB,
                maxSwapAmountTokenA,
                maxSwapAmountTokenB
            ) = _calculateMinAndMaxSwapAmounts(
                vault,
                pool,
                getRate(tokenA),
                getRate(tokenB),
                decimalsTokenA,
                decimalsTokenB,
                PRODUCTION_MIN_TRADE_AMOUNT
            );
        }
    }

    function _initPool(
        address poolToInit,
        uint256[] memory amountsIn,
        uint256 minBptOut
    ) internal override returns (uint256) {
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(poolToInit);
        uint256[] memory initialBalances = IReClammPool(poolToInit).computeInitialBalancesRaw(tokens[0], amountsIn[0]);

        return router.initialize(poolToInit, tokens, initialBalances, minBptOut, false, bytes(""));
    }
}
