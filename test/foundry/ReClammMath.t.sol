// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";

contract ReClammMathTest is Test {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Constant to increase the price by a factor 2 if increase rate is 100%.
    uint256 private constant _SECONDS_PER_DAY_WITH_ADJUSTMENT = 124649;
    uint256 private constant _MAX_BALANCE = 1e6 * 1e18;
    uint256 private constant _MIN_BALANCE = 1e18;

    function testParseIncreaseDayRate() public pure {
        uint256 value = 2123e9;
        uint256 increaseDayRateParsed = ReClammMath.parseIncreaseDayRate(value);

        assertEq(
            increaseDayRateParsed,
            value / _SECONDS_PER_DAY_WITH_ADJUSTMENT,
            "Increase day rate should be parsed correctly"
        );
    }

    function testInitializeVirtualBalances__Fuzz(uint256 balance0, uint256 balance1, uint96 sqrtQ0) public pure {
        balance0 = bound(balance0, 0, _MAX_BALANCE);
        balance1 = bound(balance1, 0, _MAX_BALANCE);
        sqrtQ0 = SafeCast.toUint96(bound(sqrtQ0, FixedPoint.ONE + 1, type(uint96).max));

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory virtualBalances = ReClammMath.initializeVirtualBalances(balancesScaled18, sqrtQ0);

        assertEq(virtualBalances[0], balance0.divDown(sqrtQ0 - FixedPoint.ONE), "Virtual balance 0 should be correct");
        assertEq(virtualBalances[1], balance1.divDown(sqrtQ0 - FixedPoint.ONE), "Virtual balance 1 should be correct");
    }

    function testCalculateInGivenOut__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenIn,
        uint256 amountGivenScaled18
    ) public pure {
        tokenIn = bound(tokenIn, 0, 1);
        uint256 tokenOut = tokenIn == 0 ? 1 : 0;

        balanceA = bound(balanceA, _MIN_BALANCE, _MAX_BALANCE);
        balanceB = bound(balanceB, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_BALANCE, _MAX_BALANCE);

        uint256 maxAmount = tokenIn == 0 ? balanceB : balanceA;
        amountGivenScaled18 = bound(amountGivenScaled18, 1, maxAmount);

        uint256 amountIn = ReClammMath.calculateInGivenOut(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );

        uint256[] memory finalBalances = new uint256[](2);
        finalBalances[0] = balanceA + virtualBalanceA;
        finalBalances[1] = balanceB + virtualBalanceB;

        uint256 invariant = finalBalances[0].mulUp(finalBalances[1]);

        uint256 expected = invariant.divUp(finalBalances[tokenOut] - amountGivenScaled18) - finalBalances[tokenIn];

        assertEq(amountIn, expected, "Amount in should be correct");
    }

    function testCalculateOutGivenIn__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenIn,
        uint256 amountGivenScaled18
    ) public pure {
        tokenIn = bound(tokenIn, 0, 1);
        uint256 tokenOut = tokenIn == 0 ? 1 : 0;

        balanceA = bound(balanceA, _MIN_BALANCE, _MAX_BALANCE);
        balanceB = bound(balanceB, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_BALANCE, _MAX_BALANCE);

        uint256 maxAmount = tokenIn == 0 ? balanceA : balanceB;
        amountGivenScaled18 = bound(amountGivenScaled18, 1, maxAmount);

        uint256 amountOut = ReClammMath.calculateOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );

        uint256[] memory finalBalances = new uint256[](2);
        finalBalances[0] = balanceA + virtualBalanceA;
        finalBalances[1] = balanceB + virtualBalanceB;

        uint256 invariant = finalBalances[0].mulUp(finalBalances[1]);

        uint256 tokenBalance = tokenOut == 0 ? balanceA : balanceB;
        uint256 expected = finalBalances[tokenOut] - invariant.divUp(finalBalances[tokenIn] + amountGivenScaled18);

        // The swap result should not be bigger than the real balance of the token out.
        expected = expected > tokenBalance ? tokenBalance : expected;

        assertEq(amountOut, expected, "Amount out should be correct");
    }

    function testIsPoolInRange__Fuzz(
        uint256 balance0,
        uint256 balance1,
        uint256 virtualBalance0,
        uint256 virtualBalance1,
        uint256 centerednessMargin
    ) public pure {
        balance0 = bound(balance0, 0, _MAX_BALANCE);
        balance1 = bound(balance1, 0, _MAX_BALANCE);
        virtualBalance0 = bound(virtualBalance0, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_BALANCE, _MAX_BALANCE);
        centerednessMargin = bound(centerednessMargin, 0, 50e16);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[0] = virtualBalance0;
        virtualBalances[1] = virtualBalance1;

        bool isInRange = ReClammMath.isPoolInRange(balancesScaled18, virtualBalances, centerednessMargin);

        assertEq(isInRange, ReClammMath.calculateCenteredness(balancesScaled18, virtualBalances) >= centerednessMargin);
    }

    function testCalculateCenteredness__Fuzz(
        uint256 balance0,
        uint256 balance1,
        uint256 virtualBalance0,
        uint256 virtualBalance1
    ) public pure {
        balance0 = bound(balance0, 0, _MAX_BALANCE);
        balance1 = bound(balance1, 0, _MAX_BALANCE);
        virtualBalance0 = bound(virtualBalance0, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_BALANCE, _MAX_BALANCE);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[0] = virtualBalance0;
        virtualBalances[1] = virtualBalance1;

        uint256 centeredness = ReClammMath.calculateCenteredness(balancesScaled18, virtualBalances);

        if (balance0 == 0 || balance1 == 0) {
            assertEq(centeredness, 0);
        } else if (ReClammMath.isAboveCenter(balancesScaled18, virtualBalances)) {
            assertEq(centeredness, balance1.mulDown(virtualBalance0).divDown(balance0.mulDown(virtualBalance1)));
        } else {
            assertEq(centeredness, balance0.mulDown(virtualBalance1).divDown(balance1.mulDown(virtualBalance0)));
        }
    }

    function testIsAboveCenter__Fuzz(
        uint256 balance0,
        uint256 balance1,
        uint256 virtualBalance0,
        uint256 virtualBalance1
    ) public pure {
        balance0 = bound(balance0, 0, _MAX_BALANCE);
        balance1 = bound(balance1, 0, _MAX_BALANCE);
        virtualBalance0 = bound(virtualBalance0, _MIN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_BALANCE, _MAX_BALANCE);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[0] = virtualBalance0;
        virtualBalances[1] = virtualBalance1;

        bool isAboveCenter = ReClammMath.isAboveCenter(balancesScaled18, virtualBalances);

        if (balance1 == 0) {
            assertEq(isAboveCenter, true);
        } else {
            assertEq(isAboveCenter, balance0.divDown(balance1) > virtualBalance0.divDown(virtualBalance1));
        }
    }

    function testCalculateSqrtQ0__Fuzz(
        uint32 currentTime,
        uint96 startSqrtQ0,
        uint96 endSqrtQ0,
        uint32 startTime,
        uint32 endTime
    ) public pure {
        endTime = SafeCast.toUint32(bound(endTime, 2, type(uint64).max));
        startTime = SafeCast.toUint32(bound(startTime, 1, endTime - 1));
        currentTime = SafeCast.toUint32(bound(currentTime, startTime, endTime));

        endSqrtQ0 = SafeCast.toUint96(bound(endSqrtQ0, FixedPoint.ONE, type(uint96).max));
        startSqrtQ0 = SafeCast.toUint96(bound(endSqrtQ0, FixedPoint.ONE, type(uint96).max));

        uint96 sqrtQ0 = ReClammMath.calculateSqrtQ0(currentTime, startSqrtQ0, endSqrtQ0, startTime, endTime);

        currentTime++;
        uint256 nextSqrtQ0 = ReClammMath.calculateSqrtQ0(currentTime, startSqrtQ0, endSqrtQ0, startTime, endTime);

        if (startSqrtQ0 >= endSqrtQ0) {
            assertLe(nextSqrtQ0, sqrtQ0, "Next sqrtQ0 should be less than current sqrtQ0");
        } else {
            assertGe(nextSqrtQ0, sqrtQ0, "Next sqrtQ0 should be greater than current sqrtQ0");
        }
    }

    function testCalculateSqrtQ0WhenCurrentTimeIsAfterEndTime() public pure {
        uint96 startSqrtQ0 = 100;
        uint96 endSqrtQ0 = 200;
        uint32 startTime = 0;
        uint32 endTime = 50;
        uint32 currentTime = 100;

        uint96 sqrtQ0 = ReClammMath.calculateSqrtQ0(currentTime, startSqrtQ0, endSqrtQ0, startTime, endTime);

        assertEq(sqrtQ0, endSqrtQ0, "SqrtQ0 should be equal to endSqrtQ0");
    }

    function testCalculateSqrtQ0WhenCurrentTimeIsBeforeStartTime() public pure {
        uint96 startSqrtQ0 = 100;
        uint96 endSqrtQ0 = 200;
        uint32 startTime = 50;
        uint32 endTime = 100;
        uint32 currentTime = 0;

        uint96 sqrtQ0 = ReClammMath.calculateSqrtQ0(currentTime, startSqrtQ0, endSqrtQ0, startTime, endTime);

        assertEq(sqrtQ0, startSqrtQ0, "SqrtQ0 should be equal to startSqrtQ0");
    }

    function testCalculateSqrtQ0WhenStartSqrtQ0IsEqualToEndSqrtQ0() public pure {
        uint96 startSqrtQ0 = 100;
        uint96 endSqrtQ0 = 100;
        uint32 startTime = 0;
        uint32 endTime = 100;
        uint32 currentTime = 50;

        uint96 sqrtQ0 = ReClammMath.calculateSqrtQ0(currentTime, startSqrtQ0, endSqrtQ0, startTime, endTime);

        assertEq(sqrtQ0, endSqrtQ0, "SqrtQ0 should be equal to endSqrtQ0");
    }
}
