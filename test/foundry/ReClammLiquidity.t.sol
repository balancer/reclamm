// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";

contract ReClammLiquidityTest is BaseReClammTest {
    using FixedPoint for uint256;

    uint256 constant _MAX_PRICE_ERROR_ABS = 5;
    uint256 constant _MAX_CENTEREDNESS_ERROR_ABS = 1e9;

    function testAddLiquidity_Fuzz(
        uint256 exactBptAmountOut,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        uint256[] memory virtualBalancesBefore = ReClammPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        uint256[] memory virtualBalancesAfter = ReClammPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountOut.divUp(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulUp(FixedPoint.ONE + proportion),
            "DAI virtual balance does not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulUp(FixedPoint.ONE + proportion),
            "USDC virtual balance does not match"
        );

        _checkPriceAndCenteredness(balancesBefore, balancesAfter, virtualBalancesBefore, virtualBalancesAfter);
    }

    function testRemoveLiquidity_Fuzz(
        uint256 exactBptAmountIn,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountIn = bound(exactBptAmountIn, 1e6, (9 * totalSupply) / 10);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        uint256[] memory virtualBalancesBefore = ReClammPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);

        vm.prank(lp);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        uint256[] memory virtualBalancesAfter = ReClammPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountIn.divUp(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulDown(FixedPoint.ONE - proportion),
            "DAI virtual balance does not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulDown(FixedPoint.ONE - proportion),
            "USDC virtual balance does not match"
        );

        _checkPriceAndCenteredness(balancesBefore, balancesAfter, virtualBalancesBefore, virtualBalancesAfter);
    }

    function _checkPriceAndCenteredness(
        uint256[] memory balancesBefore,
        uint256[] memory balancesAfter,
        uint256[] memory virtualBalancesBefore,
        uint256[] memory virtualBalancesAfter
    ) internal view {
        // Check if price is constant.
        uint256 daiPriceBefore = (balancesBefore[usdcIdx] + virtualBalancesBefore[usdcIdx]).divDown(
            balancesBefore[daiIdx] + virtualBalancesBefore[daiIdx]
        );
        uint256 daiPriceAfter = (balancesAfter[usdcIdx] + virtualBalancesAfter[usdcIdx]).divDown(
            balancesAfter[daiIdx] + virtualBalancesAfter[daiIdx]
        );
        assertApproxEqAbs(daiPriceAfter, daiPriceBefore, _MAX_PRICE_ERROR_ABS, "Price changed");

        // Check if centeredness is constant.
        uint256 centerednessBefore = ReClammMath.calculateCenteredness(balancesBefore, virtualBalancesBefore);
        uint256 centerednessAfter = ReClammMath.calculateCenteredness(balancesAfter, virtualBalancesAfter);
        assertApproxEqAbs(centerednessAfter, centerednessBefore, _MAX_CENTEREDNESS_ERROR_ABS, "Centeredness changed");
    }

    function _setPoolBalances(uint256 initialDaiBalance, uint256 initialUsdcBalance) internal {
        initialDaiBalance = bound(initialDaiBalance, 1e10, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 1e10, usdc.balanceOf(address(vault)));

        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = initialDaiBalance;
        initialBalances[usdcIdx] = initialUsdcBalance;

        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);
    }
}
