// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammMathTest is BaseReClammTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 private constant _MAX_CENTEREDNESS_ERROR_ABS = 5e7;
    uint256 private constant _MAX_PRICE_ERROR_ABS = 2e16;

    ReClammMathMock internal mathContract;

    function setUp() public override {
        super.setUp();
        mathContract = new ReClammMathMock();
    }

    function testParseDailyPriceShiftExponent() public pure {
        uint256 value = 2123e9;
        uint256 dailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(value);

        assertEq(
            dailyPriceShiftBase,
            FixedPoint.ONE - value / _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT,
            "DailyPriceShiftExponent should be parsed correctly"
        );
    }

    function testComputeInGivenOut__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenIn,
        uint256 amountGivenScaled18
    ) public pure {
        tokenIn = bound(tokenIn, 0, 1);
        uint256 tokenOut = tokenIn == 0 ? 1 : 0;

        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);

        uint256 maxAmount = tokenIn == 0 ? balanceB : balanceA;
        amountGivenScaled18 = bound(amountGivenScaled18, 1, maxAmount);

        uint256 amountIn = ReClammMath.computeInGivenOut(
            [balanceA, balanceB].toMemoryArray(),
            virtualBalanceA,
            virtualBalanceB,
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );

        uint256[] memory finalBalances = new uint256[](2);
        finalBalances[a] = balanceA + virtualBalanceA;
        finalBalances[b] = balanceB + virtualBalanceB;

        uint256 invariant = finalBalances[a].mulUp(finalBalances[b]);

        uint256 expected = invariant.divUp(finalBalances[tokenOut] - amountGivenScaled18) - finalBalances[tokenIn];

        assertEq(amountIn, expected, "Amount in should be correct");
    }

    function testComputeInGivenOutBiggerThanBalance() public {
        uint256 balanceA = 1e18;
        uint256 balanceB = 1e18;
        uint256 virtualBalanceA = 1e18;
        uint256 virtualBalanceB = 1e18;

        uint256 amountGivenScaled18 = 1e18 + 1;

        vm.expectRevert(ReClammMath.AmountOutGreaterThanBalance.selector);
        mathContract.computeInGivenOut(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
    }

    function testComputeOutGivenIn__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenIn,
        uint256 amountGivenScaled18
    ) public pure {
        tokenIn = bound(tokenIn, 0, 1);
        uint256 tokenOut = tokenIn == 0 ? 1 : 0;

        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);

        uint256 maxAmount = tokenIn == 0 ? balanceA : balanceB;
        amountGivenScaled18 = bound(amountGivenScaled18, 1, maxAmount);
        uint256 expectedAmountOutScaled18 = _computeOutGivenInAllowError(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );
        vm.assume(expectedAmountOutScaled18 < (tokenOut == 0 ? balanceA : balanceB));

        uint256 amountOut = ReClammMath.computeOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            virtualBalanceA,
            virtualBalanceB,
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );

        uint256[] memory finalBalances = new uint256[](2);
        finalBalances[a] = balanceA + virtualBalanceA;
        finalBalances[b] = balanceB + virtualBalanceB;

        uint256 invariant = finalBalances[a].mulUp(finalBalances[b]);

        uint256 tokenOutPoolAmount = invariant.divUp(finalBalances[tokenIn] + amountGivenScaled18);
        uint256 expected = finalBalances[tokenOut] - tokenOutPoolAmount;

        assertEq(amountOut, expected, "Amount out should be correct");
    }

    function testComputeOutGivenInBiggerThanBalance() public {
        // Pool heavily unbalanced, token B over valued.
        uint256 balanceA = 4e5 * 1e18;
        uint256 balanceB = 1e18;
        uint256 virtualBalanceA = 7e5 * 1e18;
        uint256 virtualBalanceB = 5e5 * 1e18;

        // This trade will return more tokens B than the real balance of the pool.
        uint256 amountGivenScaled18 = balanceA;

        vm.expectRevert(ReClammMath.AmountOutGreaterThanBalance.selector);
        mathContract.computeOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
    }

    function testComputeOutGivenInNegativeAmountOut() public {
        // This specific case was found by fuzzing. Rounding the numbers to 1e6 * 1e18 do not revert, because the
        // negative amount is caused by rounding, so exact numbers make the function to succeed.
        uint256 balanceA = 999999999901321691778599;
        uint256 balanceB = 100000000000001;
        uint256 virtualBalanceA = 999999999900433052945972;
        uint256 virtualBalanceB = 1e14;

        // This trade will return a negative amount out due to rounding.
        uint256 amountGivenScaled18 = 3;

        vm.expectRevert(ReClammMath.NegativeAmountOut.selector);
        mathContract.computeOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
    }

    function testIsPoolWithinTargetRange__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 centerednessMargin
    ) public pure {
        balanceA = bound(balanceA, 0, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, 0, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        centerednessMargin = bound(centerednessMargin, 0, 50e16);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = balanceA;
        balancesScaled18[b] = balanceB;

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[a] = virtualBalanceA;
        virtualBalances[b] = virtualBalanceB;

        bool isInRange = ReClammMath.isPoolWithinTargetRange(
            balancesScaled18,
            virtualBalances[a],
            virtualBalances[b],
            centerednessMargin
        );

        assertEq(
            isInRange,
            ReClammMath.computeCenteredness(balancesScaled18, virtualBalances[a], virtualBalances[b]) >=
                centerednessMargin
        );
    }

    function testComputeCenteredness__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) public pure {
        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = balanceA;
        balancesScaled18[b] = balanceB;

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[a] = virtualBalanceA;
        virtualBalances[b] = virtualBalanceB;

        uint256 centeredness = ReClammMath.computeCenteredness(
            balancesScaled18,
            virtualBalances[a],
            virtualBalances[b]
        );

        if (balanceA == 0 || balanceB == 0) {
            assertEq(centeredness, 0);
        } else if (ReClammMath.isAboveCenter(balancesScaled18, virtualBalances[a], virtualBalances[b])) {
            assertApproxEqAbs(
                centeredness,
                ((balanceB * virtualBalanceA) / balanceA).divUp(virtualBalanceB),
                _MAX_CENTEREDNESS_ERROR_ABS,
                "Centeredness does not match"
            );
        } else {
            assertApproxEqAbs(
                centeredness,
                ((balanceA * virtualBalanceB) / balanceB).divUp(virtualBalanceA),
                _MAX_CENTEREDNESS_ERROR_ABS,
                "Centeredness does not match"
            );
        }
    }

    function testIsAboveCenter__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) public pure {
        balanceA = bound(balanceA, 0, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, 0, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = balanceA;
        balancesScaled18[b] = balanceB;

        bool isAboveCenter = ReClammMath.isAboveCenter(balancesScaled18, virtualBalanceA, virtualBalanceB);

        if (balanceB == 0) {
            assertEq(isAboveCenter, true);
        } else {
            assertEq(isAboveCenter, balanceA.divDown(balanceB) > virtualBalanceA.divDown(virtualBalanceB));
        }
    }

    function testComputeFourthRootPriceRatio__Fuzz(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 priceRatioUpdateStartTime,
        uint32 priceRatioUpdateEndTime
    ) public pure {
        priceRatioUpdateEndTime = SafeCast.toUint32(bound(priceRatioUpdateEndTime, 2, type(uint32).max - 1));
        priceRatioUpdateStartTime = SafeCast.toUint32(bound(priceRatioUpdateStartTime, 1, priceRatioUpdateEndTime - 1));
        currentTime = SafeCast.toUint32(bound(currentTime, priceRatioUpdateStartTime, priceRatioUpdateEndTime));

        endFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, FixedPoint.ONE, type(uint96).max));
        startFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, FixedPoint.ONE, type(uint96).max));

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        currentTime++;
        uint256 nextFourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        if (startFourthRootPriceRatio >= endFourthRootPriceRatio) {
            assertLe(
                nextFourthRootPriceRatio,
                fourthRootPriceRatio,
                "Next fourthRootPriceRatio should be less than current fourthRootPriceRatio"
            );
        } else {
            assertGe(
                nextFourthRootPriceRatio,
                fourthRootPriceRatio,
                "Next fourthRootPriceRatio should be greater than current fourthRootPriceRatio"
            );
        }
    }

    function testCalculateVirtualBalancesUpdatingPriceRatio__Fuzz(
        uint256 balanceA,
        uint256 balanceB,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 expectedFourthRootPriceRatio
    ) public pure {
        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        expectedFourthRootPriceRatio = SafeCast.toUint96(bound(expectedFourthRootPriceRatio, 1.1e18, 10e18));

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = balanceA;
        balancesScaled18[b] = balanceB;

        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[a] = virtualBalanceA;
        lastVirtualBalances[b] = virtualBalanceB;

        vm.assume(_calculateCurrentPriceRatio(balancesScaled18, lastVirtualBalances) >= 1.1e18);
        vm.assume(_calculateCurrentPriceRatio(balancesScaled18, lastVirtualBalances) <= 10e18);

        bool isPoolAboveCenter = ReClammMath.isAboveCenter(
            balancesScaled18,
            lastVirtualBalances[a],
            lastVirtualBalances[b]
        );

        vm.assume(balancesScaled18[a].mulDown(lastVirtualBalances[b]) > 0);
        vm.assume(balancesScaled18[b].mulDown(lastVirtualBalances[a]) > 0);
        uint256 oldCenteredness = ReClammMath.computeCenteredness(
            balancesScaled18,
            lastVirtualBalances[a],
            lastVirtualBalances[b]
        );

        vm.assume(oldCenteredness > _MIN_POOL_CENTEREDNESS);

        uint256[] memory newVirtualBalances = new uint256[](2);
        (newVirtualBalances[a], newVirtualBalances[b]) = ReClammMath.computeVirtualBalancesWithCurrentPriceRatio(
            expectedFourthRootPriceRatio,
            balancesScaled18,
            lastVirtualBalances[a],
            lastVirtualBalances[b],
            isPoolAboveCenter
        );

        // Check if centeredness is the same
        vm.assume(balancesScaled18[a].mulDown(newVirtualBalances[b]) > 0);
        vm.assume(balancesScaled18[b].mulDown(newVirtualBalances[a]) > 0);
        uint256 newCenteredness = ReClammMath.computeCenteredness(
            balancesScaled18,
            newVirtualBalances[a],
            newVirtualBalances[b]
        );
        assertApproxEqAbs(
            newCenteredness,
            oldCenteredness,
            _MAX_CENTEREDNESS_ERROR_ABS,
            "Centeredness should be the same"
        );

        // Check if price ratio matches the new price ratio
        uint256 actualFourthRootPriceRatio = _calculateCurrentPriceRatio(balancesScaled18, newVirtualBalances);

        uint256 expectedPriceRatio = expectedFourthRootPriceRatio
            .mulDown(expectedFourthRootPriceRatio)
            .mulDown(expectedFourthRootPriceRatio)
            .mulDown(expectedFourthRootPriceRatio);

        uint256 actualPriceRatio = actualFourthRootPriceRatio
            .mulDown(actualFourthRootPriceRatio)
            .mulDown(actualFourthRootPriceRatio)
            .mulDown(actualFourthRootPriceRatio);

        assertApproxEqAbs(expectedPriceRatio, actualPriceRatio, _MAX_PRICE_ERROR_ABS, "Price Ratio should be correct");
    }

    function testComputeFourthRootPriceRatioWhenCurrentTimeIsEndTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 priceRatioUpdateStartTime = 0;
        uint32 priceRatioUpdateEndTime = 100;
        uint32 currentTime = 100;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function testComputeFourthRootPriceRatioWhenCurrentTimeIsEndTimeAndStartTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 priceRatioUpdateStartTime = 100;
        uint32 priceRatioUpdateEndTime = 100;
        uint32 currentTime = 100;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function testComputeFourthRootPriceRatioWhenCurrentTimeIsAfterEndTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 priceRatioUpdateStartTime = 0;
        uint32 priceRatioUpdateEndTime = 50;
        uint32 currentTime = 100;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function testComputeFourthRootPriceRatioWhenCurrentTimeIsStartTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 priceRatioUpdateStartTime = 50;
        uint32 priceRatioUpdateEndTime = 100;
        uint32 currentTime = 50;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            startFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to startFourthRootPriceRatio"
        );
    }

    function testComputeFourthRootPriceRatioWhenCurrentTimeIsBeforeStartTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 priceRatioUpdateStartTime = 50;
        uint32 priceRatioUpdateEndTime = 100;
        uint32 currentTime = 0;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            startFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to startFourthRootPriceRatio"
        );
    }

    function testComputeFourthRootPriceRatioWhenStartFourthRootPriceRatioIsEqualToEndFourthRootPriceRatio()
        public
        pure
    {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 100;
        uint32 priceRatioUpdateStartTime = 0;
        uint32 priceRatioUpdateEndTime = 100;
        uint32 currentTime = 50;

        uint96 fourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function testComputeCenterednessShortCircuit() public pure {
        uint256[] memory balancesScaled18 = new uint256[](2);
        uint256[] memory virtualBalances = new uint256[](2);

        balancesScaled18[b] = 1;
        uint256 centeredness = ReClammMath.computeCenteredness(
            balancesScaled18,
            virtualBalances[a],
            virtualBalances[b]
        );
        assertEq(centeredness, 0, "(0,1) non-zero centeredness with A=0");

        balancesScaled18[a] = 1;
        balancesScaled18[b] = 0;
        centeredness = ReClammMath.computeCenteredness(balancesScaled18, virtualBalances[a], virtualBalances[b]);
        assertEq(centeredness, 0, "(1,0) non-zero centeredness with B=0");
    }

    function _calculateCurrentPriceRatio(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) private pure returns (uint256 newSqrtPriceRatio) {
        uint256 invariant = ReClammMath.computeInvariant(
            balancesScaled18,
            virtualBalances[a],
            virtualBalances[b],
            Rounding.ROUND_DOWN
        );
        newSqrtPriceRatio = ReClammMath.sqrtScaled18(invariant.divDown(virtualBalances[a]).divDown(virtualBalances[b]));
    }

    function _computeOutGivenInAllowError(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) private pure returns (uint256) {
        uint256[] memory totalBalances = new uint256[](balancesScaled18.length);

        totalBalances[a] = balancesScaled18[a] + virtualBalances[a];
        totalBalances[b] = balancesScaled18[b] + virtualBalances[b];

        uint256 invariant = totalBalances[a].mulUp(totalBalances[b]);
        // Total (virtual + real) token out amount that should stay in the pool after the swap.
        uint256 tokenOutPoolAmount = invariant.divUp(totalBalances[tokenInIndex] + amountGivenScaled18);

        vm.assume(tokenOutPoolAmount <= totalBalances[tokenOutIndex]);

        return totalBalances[tokenOutIndex] - tokenOutPoolAmount;
    }
}
