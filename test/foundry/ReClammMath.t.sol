// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammMathTest is BaseReClammTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Constant to increase the price by a factor 2 if increase rate is 100%.
    uint256 private constant _SECONDS_PER_DAY_WITH_ADJUSTMENT = 124649;
    uint256 private constant _MAX_BALANCE = 1e6 * 1e18;

    uint256 private constant _MIN_POOL_CENTEREDNESS = 1e3;
    uint256 private constant _MAX_CENTEREDNESS_ERROR_ABS = 1e9;
    uint256 private constant _MAX_PRICE_ERROR_ABS = 1e14;

    ReClammMathMock internal mathContract;

    function setUp() public override {
        super.setUp();
        mathContract = new ReClammMathMock();
    }

    function testParseIncreaseDayRate() public pure {
        uint256 value = 2123e9;
        uint256 increaseDayRateParsed = ReClammMath.parseIncreaseDayRate(value);

        assertEq(
            increaseDayRateParsed,
            value / _SECONDS_PER_DAY_WITH_ADJUSTMENT,
            "Increase day rate should be parsed correctly"
        );
    }

    function testInitializeVirtualBalances__Fuzz(
        uint256 balance0,
        uint256 balance1,
        uint96 fourthRootPriceRatio
    ) public pure {
        balance0 = bound(balance0, 0, _MAX_BALANCE);
        balance1 = bound(balance1, 0, _MAX_BALANCE);
        fourthRootPriceRatio = SafeCast.toUint96(bound(fourthRootPriceRatio, FixedPoint.ONE + 1, type(uint96).max));

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory virtualBalances = ReClammMath.initializeVirtualBalances(
            balancesScaled18,
            fourthRootPriceRatio
        );

        assertEq(
            virtualBalances[0],
            balance0.divDown(fourthRootPriceRatio - FixedPoint.ONE),
            "Virtual balance 0 should be correct"
        );
        assertEq(
            virtualBalances[1],
            balance1.divDown(fourthRootPriceRatio - FixedPoint.ONE),
            "Virtual balance 1 should be correct"
        );
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

        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_BALANCE);

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

    function testCalculateInGivenOutBiggerThanBalance() public {
        uint256 balanceA = 1e18;
        uint256 balanceB = 1e18;
        uint256 virtualBalanceA = 1e18;
        uint256 virtualBalanceB = 1e18;

        uint256 amountGivenScaled18 = 1e18 + 1;

        vm.expectRevert(ReClammMath.AmountOutBiggerThanBalance.selector);
        mathContract.calculateInGivenOut(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
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

        balanceA = bound(balanceA, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        balanceB = bound(balanceB, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalanceA = bound(virtualBalanceA, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalanceB = bound(virtualBalanceB, _MIN_TOKEN_BALANCE, _MAX_BALANCE);

        uint256 maxAmount = tokenIn == 0 ? balanceA : balanceB;
        amountGivenScaled18 = bound(amountGivenScaled18, 1, maxAmount);
        uint256 expectedAmountOutScaled18 = _calculateOutGivenInAllowError(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            tokenIn,
            tokenOut,
            amountGivenScaled18
        );
        vm.assume(expectedAmountOutScaled18 < (tokenOut == 0 ? balanceA : balanceB));

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

        uint256 tokenOutPoolAmount = invariant.divUp(finalBalances[tokenIn] + amountGivenScaled18);
        uint256 expected = finalBalances[tokenOut] - tokenOutPoolAmount;

        assertEq(amountOut, expected, "Amount out should be correct");
    }

    function testCalculateOutGivenInBiggerThanBalance() public {
        // Pool heavily unbalanced, token B over valued.
        uint256 balanceA = 4e5 * 1e18;
        uint256 balanceB = 1e18;
        uint256 virtualBalanceA = 7e5 * 1e18;
        uint256 virtualBalanceB = 5e5 * 1e18;

        // This trade will return more tokens B than the real balance of the pool.
        uint256 amountGivenScaled18 = balanceA;

        vm.expectRevert(ReClammMath.AmountOutBiggerThanBalance.selector);
        mathContract.calculateOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
    }

    function testCalculateOutGivenInNegativeAmountOut() public {
        // This specific case was found by fuzzing. Rounding the numbers to 1e6 * 1e18 do not revert, because the
        // negative amount is caused by rounding, so exact numbers make the function to succeed.
        uint256 balanceA = 999999999901321691778599;
        uint256 balanceB = 100000000000001;
        uint256 virtualBalanceA = 999999999900433052945972;
        uint256 virtualBalanceB = 1e14;

        // This trade will return a negative amount out due to rounding.
        uint256 amountGivenScaled18 = 3;

        vm.expectRevert(ReClammMath.NegativeAmountOut.selector);
        mathContract.calculateOutGivenIn(
            [balanceA, balanceB].toMemoryArray(),
            [virtualBalanceA, virtualBalanceB].toMemoryArray(),
            0,
            1,
            amountGivenScaled18
        );
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
        virtualBalance0 = bound(virtualBalance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
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
        balance0 = bound(balance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        balance1 = bound(balance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance0 = bound(virtualBalance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);

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
            assertApproxEqAbs(
                centeredness,
                balance1.mulDown(virtualBalance0).divDown(balance0.mulDown(virtualBalance1)),
                _MAX_CENTEREDNESS_ERROR_ABS
            );
        } else {
            assertApproxEqAbs(
                centeredness,
                balance0.mulDown(virtualBalance1).divDown(balance1.mulDown(virtualBalance0)),
                _MAX_CENTEREDNESS_ERROR_ABS
            );
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
        virtualBalance0 = bound(virtualBalance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);

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

    function testCalculateFourthRootPriceRatio__Fuzz(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) public pure {
        endTime = SafeCast.toUint32(bound(endTime, 2, type(uint32).max - 1));
        startTime = SafeCast.toUint32(bound(startTime, 1, endTime - 1));
        currentTime = SafeCast.toUint32(bound(currentTime, startTime, endTime));

        endFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, FixedPoint.ONE, type(uint96).max));
        startFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, FixedPoint.ONE, type(uint96).max));

        uint96 fourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );

        currentTime++;
        uint256 nextFourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
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
        uint256 balance0,
        uint256 balance1,
        uint256 virtualBalance0,
        uint256 virtualBalance1,
        uint256 expectedFourthRootPriceRatio
    ) public pure {
        balance0 = bound(balance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        balance1 = bound(balance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance0 = bound(virtualBalance0, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        virtualBalance1 = bound(virtualBalance1, _MIN_TOKEN_BALANCE, _MAX_BALANCE);
        expectedFourthRootPriceRatio = SafeCast.toUint96(bound(expectedFourthRootPriceRatio, 1.1e18, 10e18));

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[0] = balance0;
        balancesScaled18[1] = balance1;

        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[0] = virtualBalance0;
        lastVirtualBalances[1] = virtualBalance1;

        vm.assume(_calculateCurrentPriceRatio(balancesScaled18, lastVirtualBalances) >= 1.1e18);
        vm.assume(_calculateCurrentPriceRatio(balancesScaled18, lastVirtualBalances) <= 10e18);

        bool isPoolAboveCenter = ReClammMath.isAboveCenter(balancesScaled18, lastVirtualBalances);

        vm.assume(balancesScaled18[0].mulDown(lastVirtualBalances[1]) > 0);
        vm.assume(balancesScaled18[1].mulDown(lastVirtualBalances[0]) > 0);
        uint256 oldCenteredness = ReClammMath.calculateCenteredness(balancesScaled18, lastVirtualBalances);

        vm.assume(oldCenteredness > _MIN_POOL_CENTEREDNESS);

        uint256[] memory newVirtualBalances = ReClammMath.calculateVirtualBalancesUpdatingPriceRatio(
            expectedFourthRootPriceRatio,
            balancesScaled18,
            lastVirtualBalances,
            isPoolAboveCenter
        );

        // Check if centeredness is the same
        vm.assume(balancesScaled18[0].mulDown(newVirtualBalances[1]) > 0);
        vm.assume(balancesScaled18[1].mulDown(newVirtualBalances[0]) > 0);
        uint256 newCenteredness = ReClammMath.calculateCenteredness(balancesScaled18, newVirtualBalances);
        assertApproxEqAbs(
            newCenteredness,
            oldCenteredness,
            _MAX_CENTEREDNESS_ERROR_ABS,
            "Centeredness should be the same"
        );

        // Check if price ratio matches the new price ratio
        uint256 invariant = ReClammMath.computeInvariant(balancesScaled18, newVirtualBalances, Rounding.ROUND_DOWN);
        uint256 actualFourthRootPriceRatio = Math.sqrt(
            (invariant * FixedPoint.ONE).divDown(newVirtualBalances[0].mulDown(newVirtualBalances[1]))
        );

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

    function testCalculateFourthRootPriceRatioWhenCurrentTimeIsAfterEndTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 startTime = 0;
        uint32 endTime = 50;
        uint32 currentTime = 100;

        uint96 fourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function testCalculateFourthRootPriceRatioWhenCurrentTimeIsBeforeStartTime() public pure {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 200;
        uint32 startTime = 50;
        uint32 endTime = 100;
        uint32 currentTime = 0;

        uint96 fourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );

        assertEq(
            fourthRootPriceRatio,
            startFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to startFourthRootPriceRatio"
        );
    }

    function testCalculateFourthRootPriceRatioWhenStartFourthRootPriceRatioIsEqualToEndFourthRootPriceRatio()
        public
        pure
    {
        uint96 startFourthRootPriceRatio = 100;
        uint96 endFourthRootPriceRatio = 100;
        uint32 startTime = 0;
        uint32 endTime = 100;
        uint32 currentTime = 50;

        uint96 fourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            currentTime,
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );

        assertEq(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            "FourthRootPriceRatio should be equal to endFourthRootPriceRatio"
        );
    }

    function _calculateCurrentPriceRatio(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) private pure returns (uint256 newSqwrtPriceRatio) {
        uint256 invariant = ReClammMath.computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_DOWN);
        newSqwrtPriceRatio = Math.sqrt(
            invariant.divDown(virtualBalances[0]).divDown(virtualBalances[1]) * FixedPoint.ONE
        );
    }

    function _calculateOutGivenInAllowError(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) private pure returns (uint256) {
        uint256[] memory totalBalances = new uint256[](balancesScaled18.length);

        totalBalances[0] = balancesScaled18[0] + virtualBalances[0];
        totalBalances[1] = balancesScaled18[1] + virtualBalances[1];

        uint256 invariant = totalBalances[0].mulUp(totalBalances[1]);
        // Total (virtual + real) token out amount that should stay in the pool after the swap.
        uint256 tokenOutPoolAmount = invariant.divUp(totalBalances[tokenInIndex] + amountGivenScaled18);

        vm.assume(tokenOutPoolAmount <= totalBalances[tokenOutIndex]);

        return totalBalances[tokenOutIndex] - tokenOutPoolAmount;
    }
}
