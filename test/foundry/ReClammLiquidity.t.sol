// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract ReClammLiquidityTest is BaseReClammTest {
    using FixedPoint for uint256;

    uint256 constant _MAX_PRICE_ERROR_ABS = 5e4;
    uint256 constant _MAX_CENTEREDNESS_ERROR_ABS = 1e6;

    function testAddLiquidity__Fuzz(
        uint256 exactBptAmountOut,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        (uint256[] memory virtualBalancesAfter, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountOut.divUp(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulUp(FixedPoint.ONE + proportion),
            "DAI virtual balances do not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulUp(FixedPoint.ONE + proportion),
            "USDC virtual balances do not match"
        );

        _checkPriceAndCenteredness(balancesBefore, balancesAfter, virtualBalancesBefore, virtualBalancesAfter);

        _checkInvariant(
            balancesBefore,
            balancesAfter,
            virtualBalancesBefore,
            virtualBalancesAfter,
            FixedPoint.ONE + proportion
        );
    }

    function testAddLiquidityOutOfRange__Fuzz(
        uint256 exactBptAmountOut,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        uint256[] memory initialBalancesScaled18 = _setPoolBalances(initialDaiBalance, initialUsdcBalance);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();

        // Make sure pool is out of range, so the virtual balances should be updated by the addLiquidity call.
        vm.assume(
            ReClammMath.isPoolWithinMargins(
                initialBalancesScaled18,
                virtualBalancesBefore,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        (uint256[] memory virtualBalancesAfter, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountOut.divUp(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulUp(FixedPoint.ONE + proportion),
            "DAI virtual balances do not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulUp(FixedPoint.ONE + proportion),
            "USDC virtual balances do not match"
        );

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesAfter[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesAfter[usdcIdx], "USDC virtual balances do not match");

        _checkInvariant(
            initialBalancesScaled18,
            balancesAfter,
            virtualBalancesBefore,
            virtualBalancesAfter,
            FixedPoint.ONE + proportion
        );
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

    function testAddLiquiditySingleTokenExactOut() public {
        // Try to add liquidity with single token - should revert
        vm.prank(alice);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.addLiquiditySingleTokenExactOut(
            pool, // pool address
            dai, // token we want to add
            1e18, // maximum DAI willing to pay
            1e18, // exact BPT amount we want to receive
            false, // wethIsEth
            "" // userData
        );
    }

    function testAddLiquidityCustom() public {
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = 1e18;
        maxAmountsIn[usdcIdx] = 1e18;

        vm.prank(alice);
        vm.expectRevert(IVaultErrors.DoesNotSupportAddLiquidityCustom.selector);
        router.addLiquidityCustom(
            pool, // pool address
            maxAmountsIn, // maximum amounts willing to pay
            1e18, // minimum BPT amount we want to receive
            false, // wethIsEth
            "" // userData
        );
    }

    function testDonate() public {
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[daiIdx] = 1e18;
        amountsIn[usdcIdx] = 1e18;

        vm.prank(alice);
        vm.expectRevert(IVaultErrors.DoesNotSupportDonation.selector);
        router.donate(
            pool, // pool address
            amountsIn, // amounts to donate
            false, // wethIsEth
            "" // userData
        );
    }

    function testRemoveLiquidity__Fuzz(
        uint256 exactBptAmountIn,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountIn = bound(exactBptAmountIn, 1e6, (9 * totalSupply) / 10);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);

        vm.prank(lp);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        (uint256[] memory virtualBalancesAfter, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountIn.divDown(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulUp(FixedPoint.ONE - proportion),
            "DAI virtual balances do not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulUp(FixedPoint.ONE - proportion),
            "USDC virtual balances do not match"
        );

        _checkPriceAndCenteredness(balancesBefore, balancesAfter, virtualBalancesBefore, virtualBalancesAfter);

        _checkInvariant(
            balancesBefore,
            balancesAfter,
            virtualBalancesBefore,
            virtualBalancesAfter,
            FixedPoint.ONE - proportion
        );
    }

    function testRemoveLiquidityOutOfRange__Fuzz(
        uint256 exactBptAmountIn,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        uint256[] memory initialBalancesScaled18 = _setPoolBalances(initialDaiBalance, initialUsdcBalance);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();

        // Make sure pool is out of range, so the virtual balances should be updated by the addLiquidity call.
        vm.assume(
            ReClammMath.isPoolWithinMargins(
                initialBalancesScaled18,
                virtualBalancesBefore,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountIn = bound(exactBptAmountIn, 1e6, (9 * totalSupply) / 10);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        vm.prank(lp);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        (uint256[] memory virtualBalancesAfter, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Check if virtual balances were correctly updated.
        uint256 proportion = exactBptAmountIn.divDown(totalSupply);
        assertEq(
            virtualBalancesAfter[daiIdx],
            virtualBalancesBefore[daiIdx].mulUp(FixedPoint.ONE - proportion),
            "DAI virtual balances do not match"
        );
        assertEq(
            virtualBalancesAfter[usdcIdx],
            virtualBalancesBefore[usdcIdx].mulUp(FixedPoint.ONE - proportion),
            "USDC virtual balances do not match"
        );

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesAfter[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesAfter[usdcIdx], "USDC virtual balances do not match");

        _checkInvariant(
            initialBalancesScaled18,
            balancesAfter,
            virtualBalancesBefore,
            virtualBalancesAfter,
            FixedPoint.ONE - proportion
        );
    }

    function testRemoveLiquidityBelowMinTokenBalance() public {
        _setPoolBalances(100 * _MIN_TOKEN_BALANCE, 100 * _MIN_TOKEN_BALANCE);

        uint256 totalSupply = vault.totalSupply(pool);
        // 99.1% of the total supply, so the LP is leaving less than _MIN_TOKEN_BALANCE in the pool.
        uint256 exactBptAmountIn = (991 * totalSupply) / 1000;

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

    function testRemoveLiquiditySingleTokenExactIn() public {
        vm.prank(lp);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.removeLiquiditySingleTokenExactIn(
            pool, // pool address
            1e18, // exact BPT amount to burn
            dai, // token we want to receive
            1e18, // minimum DAI amount we want to receive
            false, // wethIsEth
            "" // userData
        );
    }

    function testRemoveLiquidityCustom() public {
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 1e18;
        minAmountsOut[usdcIdx] = 1e18;

        vm.prank(lp);
        vm.expectRevert(IVaultErrors.DoesNotSupportRemoveLiquidityCustom.selector);
        router.removeLiquidityCustom(
            pool, // pool address
            1e18, // maximum BPT amount willing to burn
            minAmountsOut, // minimum amounts we want to receive
            false, // wethIsEth
            "" // userData
        );
    }

    function testAddRemoveLiquidityProportional__Fuzz(
        uint256 exactBptAmountOut,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set initial pool balances
        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        // Get total supply and bound BPT amount to reasonable values
        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        // Store Alice's initial balances
        uint256 aliceDaiBalanceBefore = dai.balanceOf(alice);
        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);

        // Set max amounts for add liquidity
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = aliceDaiBalanceBefore;
        maxAmountsIn[usdcIdx] = aliceUsdcBalanceBefore;

        // Add liquidity
        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        // Remove the same amount of liquidity
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountOut, minAmountsOut, false, "");

        // Check final balances are not greater than initial balances
        uint256 aliceDaiBalanceAfter = dai.balanceOf(alice);
        uint256 aliceUsdcBalanceAfter = usdc.balanceOf(alice);

        assertLe(aliceDaiBalanceAfter, aliceDaiBalanceBefore, "DAI balance should not be greater than initial");
        assertLe(aliceUsdcBalanceAfter, aliceUsdcBalanceBefore, "USDC balance should not be greater than initial");
    }

    function testAddSwapRemoveLiquidityProportional__Fuzz(
        uint256 exactBptAmountOut,
        uint256 initialDaiBalance,
        uint256 initialUsdcBalance,
        uint256 bobSwapAmountOut
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        initialDaiBalance = bound(initialDaiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        initialUsdcBalance = bound(initialUsdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set initial pool balances
        _setPoolBalances(initialDaiBalance, initialUsdcBalance);

        // Get total supply and bound BPT amount to reasonable values
        uint256 totalSupply = vault.totalSupply(pool);
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 100 * totalSupply);

        // Store initial balances of pool
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);
        uint256 poolDaiBalanceBefore = balancesBefore[daiIdx];
        uint256 poolUsdcBalanceBefore = balancesBefore[usdcIdx];

        // Set max amounts for add liquidity
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        // Add liquidity
        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        (, , uint256[] memory balancesScaled18, ) = vault.getPoolTokenInfo(pool);

        // Perform Bob's swap (DAI -> USDC)
        bobSwapAmountOut = bound(bobSwapAmountOut, 1e6, balancesScaled18[usdcIdx] - _MIN_TOKEN_BALANCE - 1);
        vm.startPrank(bob);
        router.swapSingleTokenExactOut(
            pool,
            dai,
            usdc,
            bobSwapAmountOut,
            type(uint256).max,
            type(uint256).max,
            false,
            ""
        );
        router.swapSingleTokenExactIn(pool, usdc, dai, bobSwapAmountOut, 0, type(uint256).max, false, "");
        vm.stopPrank();

        // Remove the same amount of liquidity
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;

        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountOut, minAmountsOut, false, "");

        // Check final balances of pool
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);
        uint256 poolDaiBalanceAfter = balancesAfter[daiIdx];
        uint256 poolUsdcBalanceAfter = balancesAfter[usdcIdx];

        assertGe(poolDaiBalanceAfter, poolDaiBalanceBefore, "DAI balance should not be smaller than initial");
        assertGe(poolUsdcBalanceAfter, poolUsdcBalanceBefore, "USDC balance should not be smaller than initial");
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
        uint256 centerednessBefore = ReClammMath.computeCenteredness(balancesBefore, virtualBalancesBefore);
        uint256 centerednessAfter = ReClammMath.computeCenteredness(balancesAfter, virtualBalancesAfter);
        assertApproxEqAbs(centerednessAfter, centerednessBefore, _MAX_CENTEREDNESS_ERROR_ABS, "Centeredness changed");
    }

    function _checkInvariant(
        uint256[] memory balancesBefore,
        uint256[] memory balancesAfter,
        uint256[] memory virtualBalancesBefore,
        uint256[] memory virtualBalancesAfter,
        uint256 expectedProportion
    ) internal pure {
        // The invariant of ReClamm is squared, so we need to take the sqrt of the invariant to check the
        // proportionality.
        uint256 invariantSquaredBefore = ReClammMath.computeInvariant(
            balancesBefore,
            virtualBalancesBefore,
            Rounding.ROUND_DOWN
        );

        uint256 invariantSquaredAfter = ReClammMath.computeInvariant(
            balancesAfter,
            virtualBalancesAfter,
            Rounding.ROUND_DOWN
        );

        assertApproxEqRel(
            Math.sqrt(invariantSquaredAfter * FixedPoint.ONE),
            Math.sqrt(invariantSquaredBefore * FixedPoint.ONE).mulUp(expectedProportion),
            1e6, // Error of 0.0000000001%
            "Invariant did not change proportionally"
        );
    }
}
