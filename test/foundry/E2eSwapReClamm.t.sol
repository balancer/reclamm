// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { E2eSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eSwap.t.sol";

import { ReClammPoolContractsDeployer } from "./utils/ReClammPoolContractsDeployer.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract E2eSwapReClammTest is E2eSwapTest, ReClammPoolContractsDeployer {
    using FixedPoint for uint256;

    function setUp() public override {
        E2eSwapTest.setUp();
    }

    function setUpVariables() internal override {
        sender = lp;
        poolCreator = lp;

        // 0.1% min swap fee.
        minPoolSwapFeePercentage = 0.1e16;
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
