// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { SqrtPriceRatioState } from "../../contracts/lib/ReClammMath.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";

contract ReClammRoundingTest is Test {
    uint256 constant DELTA = 1e3;

    uint256 constant MAX_TOKENS = 2;
    uint256 constant MIN_BALANCE = 1e18;
    uint256 constant MIN_AMOUNT = 1e12;
    uint256 constant MAX_AMOUNT = 1_000_000_000_000 * 1e18;
    uint256 constant MIN_SQRT_PRICE_RATIO = 10e12 + FixedPoint.ONE; // 1.00001
    uint256 constant MAX_SQRT_PRICE_RATIO = 1000e18;
    uint256 constant MAX_TIME_CONSTANT = FixedPoint.ONE - 1;

    uint256 constant MIN_SWAP_FEE = 0;
    // Max swap fee of 50%. In practice this is way too high for a static fee.
    uint256 constant MAX_SWAP_FEE = 50e16;

    ReClammMathMock mathMock;

    function setUp() public {
        mathMock = new ReClammMathMock();
    }

    function testPureComputeInvariant__Fuzz(uint256[2] memory balancesRaw, uint256 sqrtPriceRatio) public view {
        uint256[] memory balances = new uint256[](balancesRaw.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], MIN_BALANCE, MAX_AMOUNT);
        }

        sqrtPriceRatio = uint96(bound(sqrtPriceRatio, MIN_SQRT_PRICE_RATIO, MAX_SQRT_PRICE_RATIO));

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, sqrtPriceRatio);

        uint256 invariantRoundedUp = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_UP);
        uint256 invariantRoundedDown = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_DOWN);

        assertGe(
            invariantRoundedUp,
            invariantRoundedDown,
            "invariantRoundedUp < invariantRoundedDown (computeInvariant)"
        );
    }

    function testCalculateOutGivenIn___Fuzz(
        uint256[2] calldata balancesRaw,
        uint96 sqrtPriceRatio,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        uint256[] memory balances = new uint256[](balancesRaw.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], MIN_BALANCE, MAX_AMOUNT);
        }
        sqrtPriceRatio = uint96(bound(sqrtPriceRatio, MIN_SQRT_PRICE_RATIO, MAX_SQRT_PRICE_RATIO));
        amountGivenScaled18 = bound(amountGivenScaled18, MIN_AMOUNT, balances[tokenOutIndex]);

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, sqrtPriceRatio);

        mathMock.setSqrtPriceRatioState(
            SqrtPriceRatioState({
                startSqrtPriceRatio: sqrtPriceRatio,
                endSqrtPriceRatio: sqrtPriceRatio,
                startTime: 0,
                endTime: 0
            })
        );
        uint256 amountOut = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            amountGivenScaled18
        );

        uint256 roundedUpAmountIn = amountGivenScaled18 + 1;
        uint256 roundedDownAmountIn = amountGivenScaled18 - 1;

        uint256 amountOutRoundedUp = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedUpAmountIn
        );
        uint256 amountOutRoundedDown = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedDownAmountIn
        );

        assertGe(amountOutRoundedUp, amountOut, "amountOutRoundedUp < amountOut (calculateOutGivenIn)");
        assertLe(amountOutRoundedDown, amountOut, "amountOutRoundedDown > amountOut (calculateOutGivenIn)");
    }

    function testCalculateInGivenOut___Fuzz(
        uint256[2] calldata balancesRaw,
        uint96 sqrtPriceRatio,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        uint256[] memory balances = new uint256[](balancesRaw.length);
        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], MIN_BALANCE, MAX_AMOUNT);
        }
        sqrtPriceRatio = uint96(bound(sqrtPriceRatio, MIN_SQRT_PRICE_RATIO, MAX_SQRT_PRICE_RATIO));
        amountGivenScaled18 = bound(amountGivenScaled18, MIN_AMOUNT, balances[tokenOutIndex]);

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, sqrtPriceRatio);

        mathMock.setSqrtPriceRatioState(
            SqrtPriceRatioState({
                startSqrtPriceRatio: sqrtPriceRatio,
                endSqrtPriceRatio: sqrtPriceRatio,
                startTime: 0,
                endTime: 0
            })
        );
        uint256 amountIn = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            amountGivenScaled18
        );

        uint256 roundedUpAmountOut = amountGivenScaled18 + 1;
        uint256 roundedDownAmountOut = amountGivenScaled18 - 1;

        uint256 amountInRoundedUp = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedUpAmountOut
        );
        uint256 amountInRoundedDown = mathMock.calculateOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedDownAmountOut
        );

        assertGe(amountInRoundedUp, amountIn, "amountInRoundedUp < amountIn (calculateOutGivenIn)");
        assertLe(amountInRoundedDown, amountIn, "amountInRoundedDown > amountIn (calculateOutGivenIn)");
    }
}
