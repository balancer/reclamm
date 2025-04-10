// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { E2eSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";

import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammPoolContractsDeployer } from "./utils/ReClammPoolContractsDeployer.sol";
import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

contract E2eSwapReClammTest is E2eSwapFuzzPoolParamsHelper, E2eSwapTest, ReClammPoolContractsDeployer {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant MAX_BALANCE = 1_000_000_000_000 * FixedPoint.ONE;
    uint256 internal constant MIN_PRICE = FixedPoint.ONE;
    uint256 internal constant MAX_PRICE = 1_000_000_000_000 * FixedPoint.ONE;
    uint256 internal constant MAX_DAYS_FOR_PRICE_CHANGE = 10 days;

    function setUp() public override {
        E2eSwapTest.setUp();

        authorizer.grantRole(ReClammPool(address(pool)).getActionId(ReClammPool.setPriceRatioState.selector), alice);
    }

    function setUpVariables() internal override {
        sender = lp;
        poolCreator = lp;
    }

    function createPoolFactory() internal override returns (address) {
        return address(deployReClammPoolFactoryWithDefaultParams(vault));
    }

    /// @notice Overrides BaseVaultTest _createPool(). This pool is used by E2eSwapTest tests.
    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        return createReClammPool(tokens, label, vault, lp);
    }

    function fuzzPoolParams(uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params) internal override {
        _fuzzPoolParams(params, ReClammPool(pool), router, alice);
    }
}
