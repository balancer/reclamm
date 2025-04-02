// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammSwapTest is BaseReClammTest {
    using ArrayHelpers for *;

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

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(
            ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = ReClammMath.calculateInGivenOut(
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

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactIn__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 10e18);
        vm.assume(currentFourthRootPriceRatio != newFourthRootPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = ReClammMath.calculateInGivenOut(
            [poolInitAmount, poolInitAmount].toMemoryArray(),
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (poolInitAmount - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 10e18);
        vm.assume(currentFourthRootPriceRatio != newFourthRootPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(
            ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN) == false
        );

        // If the pool is out of range and price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = ReClammMath.calculateInGivenOut(
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

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN));

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = ReClammMath.calculateInGivenOut(
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

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(
            ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactOut__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 10e18);
        vm.assume(currentFourthRootPriceRatio != newFourthRootPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (poolInitAmount - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 10e18);
        vm.assume(currentFourthRootPriceRatio != newFourthRootPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(
            ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN) == false
        );

        // If the pool is out of range and prices are updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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

        uint256[] memory lastVirtualBalancesBeforeSwap = ReClammPoolMock(pool).getLastVirtualBalances();
        uint256[] memory currentVirtualBalances = ReClammPool(pool).getCurrentVirtualBalances();

        vm.assume(ReClammMath.isPoolInRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN));

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = ReClammPoolMock(pool).getLastVirtualBalances();

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
