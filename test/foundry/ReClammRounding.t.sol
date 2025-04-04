// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { PriceRatioState } from "../../contracts/lib/ReClammMath.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammRoundingTest is BaseReClammTest {
    using SafeCast for *;

    uint256 internal constant _DELTA = 1e3;

    uint256 internal constant _MIN_SWAP_AMOUNT = 1e12;

    uint256 internal constant _MIN_FOURTH_ROOT_PRICE_RATIO = 1.000001e18; // 1.000001
    uint256 internal constant _MAX_FOURTH_ROOT_PRICE_RATIO = 10e18;
    uint256 internal constant _MAX_TIME_CONSTANT = FixedPoint.ONE - 1;

    uint256 internal constant _MIN_SWAP_FEE = 0;
    // Max swap fee of 50%. In practice this is way too high for a static fee.
    uint256 internal constant _MAX_SWAP_FEE = 50e16;

    ReClammMathMock mathMock;

    function setUp() public override {
        super.setUp();
        mathMock = new ReClammMathMock();
    }

    function testPureComputeInvariant__Fuzz(uint256[2] memory balancesRaw, uint256 fourthRootPriceRatio) public view {
        uint256[] memory balances = new uint256[](balancesRaw.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], _MIN_TOKEN_BALANCE, _MAX_TOKEN_BALANCE);
        }

        fourthRootPriceRatio = bound(fourthRootPriceRatio, _MIN_FOURTH_ROOT_PRICE_RATIO, _MAX_FOURTH_ROOT_PRICE_RATIO)
            .toUint96();

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, fourthRootPriceRatio);

        uint256 invariantRoundedUp = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_UP);
        uint256 invariantRoundedDown = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_DOWN);

        assertGe(
            invariantRoundedUp,
            invariantRoundedDown,
            "invariantRoundedUp < invariantRoundedDown (computeInvariant)"
        );
    }

    function testCalculateOutGivenIn__Fuzz(
        uint256[2] calldata balancesRaw,
        uint96 fourthRootPriceRatio,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        uint256[] memory balances = new uint256[](balancesRaw.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], _MIN_TOKEN_BALANCE + 1, _MAX_TOKEN_BALANCE);
        }
        fourthRootPriceRatio = bound(fourthRootPriceRatio, _MIN_FOURTH_ROOT_PRICE_RATIO, _MAX_FOURTH_ROOT_PRICE_RATIO)
            .toUint96();

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, fourthRootPriceRatio);

        // Calculate maxAmountIn to make sure the transaction won't revert.
        uint256 maxAmountIn = mathMock.calculateInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            balances[tokenOutIndex] - _MIN_TOKEN_BALANCE - 1
        );

        vm.assume(_MIN_SWAP_AMOUNT <= maxAmountIn);
        amountGivenScaled18 = bound(amountGivenScaled18, _MIN_SWAP_AMOUNT, maxAmountIn);
        mathMock.setPriceRatioState(
            PriceRatioState({
                startFourthRootPriceRatio: fourthRootPriceRatio,
                endFourthRootPriceRatio: fourthRootPriceRatio,
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

    function testCalculateInGivenOut__Fuzz(
        uint256[2] calldata balancesRaw,
        uint96 fourthRootPriceRatio,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        uint256[] memory balances = new uint256[](balancesRaw.length);
        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        for (uint256 i = 0; i < balances.length; ++i) {
            balances[i] = bound(balancesRaw[i], _MIN_TOKEN_BALANCE + 1, _MAX_TOKEN_BALANCE);
        }
        fourthRootPriceRatio = bound(fourthRootPriceRatio, _MIN_FOURTH_ROOT_PRICE_RATIO, _MAX_FOURTH_ROOT_PRICE_RATIO)
            .toUint96();

        vm.assume(_MIN_SWAP_AMOUNT <= balances[tokenOutIndex] - _MIN_TOKEN_BALANCE - 1);
        amountGivenScaled18 = bound(
            amountGivenScaled18,
            _MIN_SWAP_AMOUNT,
            balances[tokenOutIndex] - _MIN_TOKEN_BALANCE - 1
        );

        uint256[] memory virtualBalances = mathMock.initializeVirtualBalances(balances, fourthRootPriceRatio);

        mathMock.setPriceRatioState(
            PriceRatioState({
                startFourthRootPriceRatio: fourthRootPriceRatio,
                endFourthRootPriceRatio: fourthRootPriceRatio,
                startTime: 0,
                endTime: 0
            })
        );
        uint256 amountIn = mathMock.calculateInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            amountGivenScaled18
        );

        uint256 roundedUpAmountOut = amountGivenScaled18 + 1;
        uint256 roundedDownAmountOut = amountGivenScaled18 - 1;

        uint256 amountInRoundedUp = mathMock.calculateInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedUpAmountOut
        );
        uint256 amountInRoundedDown = mathMock.calculateInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedDownAmountOut
        );

        assertGe(amountInRoundedUp, amountIn, "amountInRoundedUp < amountIn (calculateInGivenOut)");
        assertLe(amountInRoundedDown, amountIn, "amountInRoundedDown > amountIn (calculateInGivenOut)");
    }
}
