// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammSwapTest is BaseReClammTest {
    using FixedPoint for *;
    using ArrayHelpers for *;

    ReClammMathMock mathMock = new ReClammMathMock();

    function testOutOfRangeSwapExactIn__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactIn__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 2e18);

        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);

        uint256 amountUsdcIn = mathMock.computeInGivenOut(
            balancesScaled18,
            currentVirtualBalances,
            usdcIdx,
            daiIdx,
            (balancesScaled18[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, usdc, dai, amountUsdcIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangePriceRatioUpdatingSwapExactIn__Fuzz(
        uint256 daiBalance,
        uint256 usdcBalance,
        uint256 newFourthRootPriceRatio
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 1.6e18);
        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range and price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangeSwapExactIn__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN)
        );

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangeSwapExactOut__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactOut__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 2e18);

        if (newFourthRootPriceRatio > currentFourthRootPriceRatio) {
            vm.assume(newFourthRootPriceRatio - currentFourthRootPriceRatio >= 2);
        } else {
            vm.assume(currentFourthRootPriceRatio - newFourthRootPriceRatio >= 2);
        }

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiOut = (poolInitAmount - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, usdc, dai, amountDaiOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangePriceRatioUpdatingSwapExactOut__Fuzz(
        uint256 daiBalance,
        uint256 usdcBalance,
        uint256 newFourthRootPriceRatio
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 1.6e18);
        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range and prices are updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangeSwapExactOut__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN)
        );

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);
        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);
        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function _assertVirtualBalancesMatch(
        uint256[] memory virtualBalances1,
        uint256[] memory virtualBalances2
    ) internal view {
        assertEq(virtualBalances1[daiIdx], virtualBalances2[daiIdx], "DAI virtual balances do not match");
        assertEq(virtualBalances1[usdcIdx], virtualBalances2[usdcIdx], "USDC virtual balances do not match");
    }

    function _assertVirtualBalancesDoNotMatch(
        uint256[] memory virtualBalances1,
        uint256[] memory virtualBalances2
    ) internal view {
        assertNotEq(virtualBalances1[daiIdx], virtualBalances2[daiIdx], "DAI virtual balances remain unchanged");
        assertNotEq(virtualBalances1[usdcIdx], virtualBalances2[usdcIdx], "USDC virtual balances remain unchanged");
    }
}

/**
 * @notice Regression for the original Cantina report on the long-idle bricked-pool scenario.
 * @dev Reproduces the path that originally bricked the pool: drain one side via a swap, idle for ~12 days
 * so the lazy out-of-range update decays the smaller virtual balance below the historical safe floor (1e9),
 * then make a small swap. Under the old `mulDown(Va, Va)` formulation, the small swap (and any subsequent
 * operation) would panic with division by zero in `computePriceRange`. Under the algebraically rearranged
 * `computePriceRatio` (which avoids `mulDown(Va, Va)` entirely), the swap succeeds and the pool stays
 * usable even with one virtual balance well below 1e9.
 *
 * The pool init amount is intentionally small so the post-decay virtual balance lands in the historically
 * unsafe range, exercising the math at the small-VB regime that the rearrangement is designed to handle.
 */
contract ReClammLongIdleDrainTest is BaseReClammTest {
    function setUp() public override {
        poolInitAmount = 1e12;
        super.setUp();
    }

    function testLongIdleDrainStaysUsable() public {
        (, , uint256[] memory balancesBeforeDrain, ) = vault.getPoolTokenInfo(pool);

        // Identify token A (the one we will drain, sorted index 0) and token B (sorted index 1).
        (address tokenA, address tokenB) = daiIdx == 0 ? (address(dai), address(usdc)) : (address(usdc), address(dai));

        // Drain all of token A by swapping token B in.
        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            IERC20(tokenB),
            IERC20(tokenA),
            balancesBeforeDrain[0],
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Long idle period that drives the lazy virtual balance update down toward the historical 1e9 floor.
        vm.warp(block.timestamp + 11 days + 22 hours);

        // First small swap. Under the old math this committed a degraded virtual balance to storage; under
        // the new math the result is well-defined and the swap succeeds.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, IERC20(tokenB), IERC20(tokenA), 1, 0, MAX_UINT256, false, bytes(""));

        (uint256 vaAfterFirstSwap, uint256 vbAfterFirstSwap) = ReClammPool(pool).getLastVirtualBalances();
        assertLt(vaAfterFirstSwap, 1e9, "Va should have decayed below the historical safe floor");
        assertGt(vaAfterFirstSwap, 0, "Va should be strictly positive");
        assertGt(vbAfterFirstSwap, 0, "Vb should be strictly positive");

        // A short additional idle period.
        vm.warp(block.timestamp + 1 hours);

        // Under the old math, both of the following would panic with division by zero. Under the new math
        // they both succeed.
        ReClammPool(pool).computeCurrentVirtualBalances();

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, IERC20(tokenB), IERC20(tokenA), 1, 0, MAX_UINT256, false, bytes(""));
    }
}
