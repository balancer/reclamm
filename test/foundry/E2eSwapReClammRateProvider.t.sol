// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {
    E2eSwapRateProviderTest,
    PoolFactoryMock
} from "@balancer-labs/v3-vault/test/foundry/E2eSwapRateProvider.t.sol";

import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

contract E2eSwapReClammRateProvider is E2eSwapFuzzPoolParamsHelper, E2eSwapRateProviderTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;
    using CastingHelpers for address[];

    bool isFuzzPoolParams;

    function setUp() public override {
        setDefaultAccountBalance(type(uint128).max);
        super.setUp();

        exactInOutDecimalsErrorMultiplier = 2e9;
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
    ) internal virtual override returns (address newPool, bytes memory poolArgs) {
        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[tokenAIdx] = IRateProvider(address(rateProviderTokenA));
        rateProviders[tokenBIdx] = IRateProvider(address(rateProviderTokenB));

        (newPool, poolArgs) = createReClammPool(tokens, rateProviders, label, vault, lp);
    }

    function fuzzPoolParams(uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params) internal override {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        (poolInitAmountTokenA, poolInitAmountTokenB) = _fuzzPoolParams(ReClammPoolMock(pool), params);

        isFuzzPoolParams = true;
        calculateMinAndMaxSwapAmounts();
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
}
