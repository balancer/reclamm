// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseAclAmmTest } from "./utils/BaseAclAmmTest.sol";
import { AclAmmPool } from "../../contracts/AclAmmPool.sol";
import { AclAmmMath } from "../../contracts/lib/AclAmmMath.sol";

contract AclAmmLiquidityTest is BaseAclAmmTest {
    using FixedPoint for uint256;

    function testAddLiquidity_Fuzz(uint256 exactBptAmountOut) public {
        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        uint256[] memory virtualBalancesBefore = AclAmmPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);
        uint256 daiPriceBefore = (balancesBefore[usdcIdx] + virtualBalancesBefore[usdcIdx]).divDown(
            balancesBefore[daiIdx] + virtualBalancesBefore[daiIdx]
        );

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        uint256[] memory virtualBalancesAfter = AclAmmPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);
        uint256 daiPriceAfter = (balancesAfter[usdcIdx] + virtualBalancesAfter[usdcIdx]).divDown(
            balancesAfter[daiIdx] + virtualBalancesAfter[daiIdx]
        );

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

        // Check if price is constant.
        assertEq(daiPriceAfter, daiPriceBefore, "Price changed");

        // Check if centeredness is constant.
        uint256 centerednessBefore = AclAmmMath.calculateCenteredness(balancesBefore, virtualBalancesBefore);
        uint256 centerednessAfter = AclAmmMath.calculateCenteredness(balancesAfter, virtualBalancesAfter);
        assertEq(centerednessAfter, centerednessBefore, "Centeredness changed");
    }

    function testRemoveLiquidity_Fuzz(uint256 exactBptAmountIn) public {
        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountIn = bound(exactBptAmountIn, 1e6, (9 * totalSupply) / 10);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        uint256[] memory virtualBalancesBefore = AclAmmPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);
        uint256 daiPriceBefore = (balancesBefore[usdcIdx] + virtualBalancesBefore[usdcIdx]).divDown(
            balancesBefore[daiIdx] + virtualBalancesBefore[daiIdx]
        );

        vm.prank(lp);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        uint256[] memory virtualBalancesAfter = AclAmmPool(pool).getLastVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);
        uint256 daiPriceAfter = (balancesAfter[usdcIdx] + virtualBalancesAfter[usdcIdx]).divDown(
            balancesAfter[daiIdx] + virtualBalancesAfter[daiIdx]
        );

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

        // Check if price is constant.
        assertEq(daiPriceAfter, daiPriceBefore, "Price changed");

        // Check if centeredness is constant.
        uint256 centerednessBefore = AclAmmMath.calculateCenteredness(balancesBefore, virtualBalancesBefore);
        uint256 centerednessAfter = AclAmmMath.calculateCenteredness(balancesAfter, virtualBalancesAfter);
        assertEq(centerednessAfter, centerednessBefore, "Centeredness changed");
    }
}
