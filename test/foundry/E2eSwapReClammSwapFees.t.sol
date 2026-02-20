// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ProtocolFeeControllerMock } from "@balancer-labs/v3-vault/contracts/test/ProtocolFeeControllerMock.sol";
import { E2eSwapTest, E2eTestState, SwapLimits } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";

contract E2eSwapReClammSwapFeesTest is E2eSwapTest, E2eSwapFuzzPoolParamsHelper {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Indicates whether to use fuzzed pool parameters. If false, standard computeSwapLimits is used,
    // as not all tests inside E2ESwap utilize fuzzPoolState.
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
        state.swapLimits = computeSwapLimits();

        // Set swap fee to 99%, increasing the price ratio of the pool.
        vault.manualUnsafeSetStaticSwapFeePercentage(pool, 99e16); // 99% swap fee
        vm.prank(state.poolCreator);
        // Set pool creator fee to 10%, so part of the fees are collected by the pool.
        ProtocolFeeControllerMock(address(feeController)).manualSetPoolCreatorSwapFeePercentage(pool, uint256(10e16));

        uint256 amountIn = poolInitAmountTokenA / 3;

        vm.startPrank(alice);
        for (uint256 i = 0; i < 50; i++) {
            router.swapSingleTokenExactIn(pool, tokenA, tokenB, amountIn, 0, MAX_UINT256, false, bytes(""));
            router.swapSingleTokenExactOut(
                pool,
                tokenB,
                tokenA,
                // Since the swap fee is 99%, an amount out of 1% of amount in will make sure that the amount in of
                // token B is equivalent to the previous swap. We can't use "exact in" since the balances are
                // different, so the tokens may have different values.
                amountIn / 100,
                MAX_UINT256,
                MAX_UINT256,
                false,
                bytes("")
            );
        }
        vm.stopPrank();

        // Collect any fees generated during pool setup, so the E2E test will only check the fees from the test.
        feeController.collectAggregateFees(pool);

        // Warp 6 hours, so the pool can feel the impact of fees (specially if it's out of range).
        vm.warp(block.timestamp + 6 hours);

        vm.prank(state.poolCreator);
        // Set pool creator fee to 100%, so E2E tests assumptions do not break.
        ProtocolFeeControllerMock(address(feeController)).manualSetPoolCreatorSwapFeePercentage(pool, FixedPoint.ONE);

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
        uint256[] memory initialBalances = ReClammPool(pool).computeInitialBalancesRaw(tokens[0], amountsIn[0]);
        return router.initialize(poolToInit, tokens, initialBalances, minBptOut, false, bytes(""));
    }
}
