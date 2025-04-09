// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { E2eBatchSwapTest } from "@balancer-labs/v3-vault/test/foundry/E2eBatchSwap.t.sol";

import { ReClammPoolContractsDeployer } from "./utils/ReClammPoolContractsDeployer.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract E2eBatchSwapReClammTest is E2eBatchSwapTest, ReClammPoolContractsDeployer {
    using FixedPoint for uint256;

    /// @notice Overrides BaseVaultTest _createPool(). This pool is used by E2eBatchSwapTest tests.
    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address, bytes memory) {
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

    function _setUpVariables() internal override {
        tokenA = dai;
        tokenB = usdc;
        tokenC = ERC20TestToken(address(weth));
        tokenD = wsteth;
        sender = lp;
        poolCreator = lp;

        // If there are swap fees, the amountCalculated may be lower than MIN_TRADE_AMOUNT. So, multiplying
        // MIN_TRADE_AMOUNT by 10 creates a margin.
        minSwapAmountTokenA = 10 * PRODUCTION_MIN_TRADE_AMOUNT;
        minSwapAmountTokenD = 10 * PRODUCTION_MIN_TRADE_AMOUNT;

        // Divide init amount by 10 to make sure weighted math ratios are respected (Cannot trade more than 30% of pool
        // balance).
        maxSwapAmountTokenA = poolInitAmount / 10;
        maxSwapAmountTokenD = poolInitAmount / 10;
    }
}
