// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {
    E2eSwapRateProviderTest,
    E2eTestState,
    SwapLimits
} from "@balancer-labs/v3-vault/test/foundry/E2eSwapRateProvider.t.sol";

import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";

contract E2eSwapReClammRateProvider is E2eSwapRateProviderTest, E2eSwapFuzzPoolParamsHelper {
    using ArrayHelpers for *;
    using FixedPoint for uint256;
    using CastingHelpers for address[];

    bool isFuzzPoolParams;

    function setUp() public override {
        setDefaultAccountBalance(type(uint128).max);
        super.setUp();
    }

    function setUpVariables(E2eTestState memory state) internal view override returns (E2eTestState memory) {
        state.sender = lp;
        state.poolCreator = lp;
        state.exactInOutDecimalsErrorMultiplier = 2e9;
        state.amountInExactInOutError = 9e14;
        return state;
    }

    function createPoolFactory() internal override returns (address) {
        return address(deployReClammPoolFactoryWithDefaultParams(vault));
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal virtual override returns (address newPool, bytes memory poolArgs) {
        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[tokenAIdx] = IRateProvider(address(rateProviderTokenA));
        rateProviders[tokenBIdx] = IRateProvider(address(rateProviderTokenB));

        (newPool, poolArgs) = createReClammPool(tokens, rateProviders, label, vault, lp);
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

    function fuzzPoolState(
        uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params,
        E2eTestState memory state
    ) internal override returns (E2eTestState memory) {
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
        state.swapLimits = computeSwapLimits();

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

    /// Skip non-specific tests that do not fuzz pool internal parameters.

    function testDoUndoExactInFees__Fuzz(uint256) public override {
        vm.skip(true);
    }

    function testDoUndoExactInSwapAmount__Fuzz(uint256) public override {
        vm.skip(true);
    }

    function testDoUndoExactOutFees__Fuzz(uint256) public override {
        vm.skip(true);
    }

    function testDoUndoExactOutSwapAmount__Fuzz(uint256) public override {
        vm.skip(true);
    }
}
