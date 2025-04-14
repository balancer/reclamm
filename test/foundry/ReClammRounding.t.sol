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
    using FixedPoint for uint256;

    uint256 internal constant _DELTA = 1e3;

    uint256 internal constant _MIN_SWAP_AMOUNT = 1e12;

    uint256 internal constant _MIN_SWAP_FEE = 0;
    // Max swap fee of 50%. In practice this is way too high for a static fee.
    uint256 internal constant _MAX_SWAP_FEE = 50e16;

    ReClammMathMock mathMock;

    function setUp() public override {
        super.setUp();
        mathMock = new ReClammMathMock();
    }

    function testPureComputeInvariant__Fuzz(uint256 minPrice, uint256 maxPrice, uint256 targetPrice) public view {
        minPrice = bound(minPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        maxPrice = bound(maxPrice, minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        targetPrice = bound(
            targetPrice,
            minPrice + minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            maxPrice - minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        (uint256[] memory balances, uint256[] memory virtualBalances, ) = mathMock
            .computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

        uint256 invariantRoundedUp = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_UP);
        uint256 invariantRoundedDown = mathMock.computeInvariant(balances, virtualBalances, Rounding.ROUND_DOWN);

        assertGe(
            invariantRoundedUp,
            invariantRoundedDown,
            "invariantRoundedUp < invariantRoundedDown (computeInvariant)"
        );
    }

    function testComputeOutGivenIn__Fuzz(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        minPrice = bound(minPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        maxPrice = bound(maxPrice, minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        targetPrice = bound(
            targetPrice,
            minPrice + minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            maxPrice - minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        (uint256[] memory balances, uint256[] memory virtualBalances, uint256 fourthRootPriceRatio) = mathMock
            .computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        vm.assume(balances[tokenOutIndex] > _MIN_TOKEN_BALANCE);
        vm.assume(balances[tokenInIndex] > _MIN_TOKEN_BALANCE);

        // Calculate maxAmountIn to make sure the transaction won't revert.
        uint256 maxAmountIn = mathMock.computeInGivenOut(
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
                startFourthRootPriceRatio: fourthRootPriceRatio.toUint96(),
                endFourthRootPriceRatio: fourthRootPriceRatio.toUint96(),
                priceRatioUpdateStartTime: 0,
                priceRatioUpdateEndTime: 0
            })
        );
        uint256 amountOut = mathMock.computeOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            amountGivenScaled18
        );

        // Assume the pool has enough balance to pay the swap.
        vm.assume(amountOut <= balances[tokenOutIndex] - _MIN_TOKEN_BALANCE);

        uint256 roundedUpAmountIn = amountGivenScaled18 + 1;
        uint256 roundedDownAmountIn = amountGivenScaled18 - 1;

        uint256 amountOutRoundedUp = mathMock.computeOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedUpAmountIn
        );
        uint256 amountOutRoundedDown = mathMock.computeOutGivenIn(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedDownAmountIn
        );

        assertGe(amountOutRoundedUp, amountOut, "amountOutRoundedUp < amountOut (computeOutGivenIn)");
        assertLe(amountOutRoundedDown, amountOut, "amountOutRoundedDown > amountOut (computeOutGivenIn)");
    }

    function testComputeInGivenOut__Fuzz(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        bool isTokenAIn,
        uint256 amountGivenScaled18
    ) external {
        minPrice = bound(minPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        maxPrice = bound(maxPrice, minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        targetPrice = bound(
            targetPrice,
            minPrice + minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            maxPrice - minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        (uint256[] memory balances, uint256[] memory virtualBalances, uint256 fourthRootPriceRatio) = mathMock
            .computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

        (uint256 tokenInIndex, uint256 tokenOutIndex) = isTokenAIn ? (0, 1) : (1, 0);

        vm.assume(balances[tokenOutIndex] > _MIN_TOKEN_BALANCE);
        vm.assume(balances[tokenInIndex] > _MIN_TOKEN_BALANCE);

        vm.assume(_MIN_SWAP_AMOUNT <= balances[tokenOutIndex] - _MIN_TOKEN_BALANCE - 1);
        amountGivenScaled18 = bound(
            amountGivenScaled18,
            _MIN_SWAP_AMOUNT,
            balances[tokenOutIndex] - _MIN_TOKEN_BALANCE - 1
        );

        mathMock.setPriceRatioState(
            PriceRatioState({
                startFourthRootPriceRatio: fourthRootPriceRatio.toUint96(),
                endFourthRootPriceRatio: fourthRootPriceRatio.toUint96(),
                priceRatioUpdateStartTime: 0,
                priceRatioUpdateEndTime: 0
            })
        );
        uint256 amountIn = mathMock.computeInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            amountGivenScaled18
        );

        uint256 roundedUpAmountOut = amountGivenScaled18 + 1;
        uint256 roundedDownAmountOut = amountGivenScaled18 - 1;

        uint256 amountInRoundedUp = mathMock.computeInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedUpAmountOut
        );
        uint256 amountInRoundedDown = mathMock.computeInGivenOut(
            balances,
            virtualBalances,
            tokenInIndex,
            tokenOutIndex,
            roundedDownAmountOut
        );

        assertGe(amountInRoundedUp, amountIn, "amountInRoundedUp < amountIn (computeInGivenOut)");
        assertLe(amountInRoundedDown, amountIn, "amountInRoundedDown > amountIn (computeInGivenOut)");
    }
}
