// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { E2eSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";

import { ReClammPoolContractsDeployer } from "./utils/ReClammPoolContractsDeployer.sol";

contract E2eSwapReClammTest is E2eSwapTest, ReClammPoolContractsDeployer {
    function setUp() public override {
        E2eSwapTest.setUp();
    }

    function setUpVariables() internal override {
        sender = lp;
        poolCreator = lp;

        // 0.0001% max swap fee.
        minPoolSwapFeePercentage = 1e12;
        // 10% max swap fee.
        maxPoolSwapFeePercentage = 10e16;
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
}
