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
import { E2eSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";

import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

contract E2eSwapReClammTest is E2eSwapFuzzPoolParamsHelper, E2eSwapTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    function setUp() public override {
        setDefaultAccountBalance(type(uint128).max);
        E2eSwapTest.setUp();
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

    function fuzzPoolParams(uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params) internal override {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        (pool, poolArguments, poolInitAmountTokenA, poolInitAmountTokenB) = _fuzzPoolParams(
            params,
            router,
            vault,
            authorizer,
            tokens,
            "reClammPool",
            lp
        );
    }

    function _initPool(
        address poolToInit,
        uint256[] memory amountsIn,
        uint256 minBptOut
    ) internal override returns (uint256) {
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(poolToInit);
        uint256 balanceRatio = ReClammPool(poolToInit).computeInitialBalanceRatio();

        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[0] = amountsIn[0];
        initialBalances[1] = amountsIn[0].mulDown(balanceRatio);

        return router.initialize(poolToInit, tokens, initialBalances, minBptOut, false, bytes(""));
    }
}
