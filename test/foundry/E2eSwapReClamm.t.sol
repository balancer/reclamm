// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { E2eSwapTest, E2eTestState, SwapLimits } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

contract E2eSwapReClammTest is E2eSwapTest, E2eSwapFuzzPoolParamsHelper {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Indicates whether to use fuzzed pool parameters.
    bool isFuzzPoolParams;

    function setUp() public override {
        setDefaultAccountBalance(type(uint128).max);
        super.setUp();
    }

    function setUpVariables(E2eTestState memory state) internal view override returns (E2eTestState memory) {
        state.sender = lp;
        state.poolCreator = lp;
        state.exactInOutDecimalsErrorMultiplier = 2e9;
        state.amountInExactInOutError = 9e12;
        return state;
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

    function fuzzPoolState(
        uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params,
        E2eTestState memory state
    ) internal override returns (E2eTestState memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        (poolInitAmountTokenA, poolInitAmountTokenB) = _fuzzPoolParams(
            ReClammPoolMock(pool),
            params,
            getRate(tokenA),
            getRate(tokenB),
            decimalsTokenA,
            decimalsTokenB
        );

        _donateToVault();

        isFuzzPoolParams = true;

        setPoolBalances(poolInitAmountTokenA, poolInitAmountTokenB);

        // Update swap limits in state
        SwapLimits memory limits = computeSwapLimits();
        state.swapLimits = limits;

        return state;
    }

    function computeSwapLimits() internal override returns (SwapLimits memory swapLimits) {
        if (isFuzzPoolParams == false) {
            return super.computeSwapLimits();
        } else {
            (
                swapLimits.minTokenA,
                swapLimits.minTokenB,
                swapLimits.maxTokenA,
                swapLimits.maxTokenB
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
        uint256[] memory initialBalances = ReClammPool(poolToInit).computeInitialBalancesRaw(tokens[0], amountsIn[0]);

        return router.initialize(poolToInit, tokens, initialBalances, minBptOut, false, bytes(""));
    }
}
