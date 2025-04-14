// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { PriceRatioState, ReClammMath } from "../lib/ReClammMath.sol";

contract ReClammMathMock {
    PriceRatioState private _priceRatioState;

    function setPriceRatioState(PriceRatioState memory priceRatioState) external {
        _priceRatioState = priceRatioState;
    }

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        uint256 c,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        Rounding rounding
    ) external view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                lastVirtualBalanceA,
                lastVirtualBalanceB,
                c,
                lastTimestamp,
                centerednessMargin,
                _priceRatioState,
                rounding
            );
    }

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        Rounding rounding
    ) external pure returns (uint256) {
        return ReClammMath.computeInvariant(balancesScaled18, virtualBalanceA, virtualBalanceB, rounding);
    }

    function computeOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.computeOutGivenIn(
                balancesScaled18,
                virtualBalanceA,
                virtualBalanceB,
                tokenInIndex,
                tokenOutIndex,
                amountGivenScaled18
            );
    }

    function computeInGivenOut(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.computeInGivenOut(
                balancesScaled18,
                virtualBalanceA,
                virtualBalanceB,
                tokenInIndex,
                tokenOutIndex,
                amountGivenScaled18
            );
    }

    function computeTheoreticalPriceRatioAndBalances(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice
    )
        external
        pure
        returns (
            uint256[] memory realBalances,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 fourthRootPriceRatio
        )
    {
        return ReClammMath.computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);
    }

    function computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        uint256 priceShiftDailyRateInSeconds,
        uint32 lastTimestamp,
        uint64 centerednessMargin
    ) external view returns (uint256 virtualBalanceA, uint256 virtualBalanceB, bool changed) {
        return
            ReClammMath.computeCurrentVirtualBalances(
                balancesScaled18,
                lastVirtualBalanceA,
                lastVirtualBalanceB,
                priceShiftDailyRateInSeconds,
                lastTimestamp,
                centerednessMargin,
                _priceRatioState
            );
    }

    function isPoolWithinTargetRange(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 centerednessMargin
    ) external pure returns (bool) {
        return
            ReClammMath.isPoolWithinTargetRange(balancesScaled18, virtualBalanceA, virtualBalanceB, centerednessMargin);
    }

    function computeCenteredness(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) external pure returns (uint256) {
        return ReClammMath.computeCenteredness(balancesScaled18, virtualBalanceA, virtualBalanceB);
    }

    function computeFourthRootPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) external pure returns (uint256) {
        return
            ReClammMath.computeFourthRootPriceRatio(
                currentTime,
                startFourthRootPriceRatio,
                endFourthRootPriceRatio,
                startTime,
                endTime
            );
    }

    function isAboveCenter(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) external pure returns (bool) {
        return ReClammMath.isAboveCenter(balancesScaled18, virtualBalanceA, virtualBalanceB);
    }

    function computePriceShiftDailyRate(uint256 priceShiftDailyRate) external pure returns (uint256) {
        return ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);
    }
}
