// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract ReClammLiquidityTest is BaseReClammTest {
    using FixedPoint for uint256;

    uint256 constant _MAX_PRICE_ERROR_ABS = 5;
    uint256 constant _MAX_CENTEREDNESS_ERROR_ABS = 1e5;
    uint256 constant _MIN_TOKEN_BALANCE = 1e14;

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

    function testAddLiquidityUnbalanced() public {
        // Create unbalanced amounts where we try to add more DAI than USDC
        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[daiIdx] = 2e18; // 2 DAI
        exactAmountsIn[usdcIdx] = 1e18; // 1 USDC

        // Attempt to add liquidity unbalanced - should revert
        vm.prank(alice);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.addLiquidityUnbalanced(pool, exactAmountsIn, 0, false, "");
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

    function testRemoveLiquidityBelowMinTokenBalance() public {
        _setPoolBalances(100 * _MIN_TOKEN_BALANCE, 100 * _MIN_TOKEN_BALANCE);

        uint256 totalSupply = vault.totalSupply(pool);
        // 99% of the total supply + 1, so the LP is leaving less than _MIN_TOKEN_BALANCE in the pool.
        uint256 exactBptAmountIn = (99 * totalSupply) / 100 + 1;

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        vm.prank(lp);
        vm.expectRevert(IReClammPool.TokenBalanceTooLow.selector);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");
    }

    function testRemoveLiquiditySingleTokenExactOut() public {
        // Try to remove liquidity with exact token output - should revert
        vm.prank(lp);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.removeLiquiditySingleTokenExactOut(
            pool, // pool address
            1e18, // maximum BPT willing to burn
            dai, // token we want to receive
            1e18, // exact amount of DAI we want to receive
            false, // wethIsEth
            "" // userData
        );
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
        // Setting initial balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        uint256[] memory initialBalances = new uint256[](2);
        initialBalances[daiIdx] = initialDaiBalance;
        initialBalances[usdcIdx] = initialUsdcBalance;

        vault.manualSetPoolBalances(pool, initialBalances, initialBalances);
    }
}
