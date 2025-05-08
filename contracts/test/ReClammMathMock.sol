// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { PriceRatioState, ReClammMath, a, b } from "../lib/ReClammMath.sol";

contract ReClammMathMock {
    PriceRatioState private _priceRatioState;

    function setPriceRatioState(PriceRatioState memory priceRatioState) external {
        _priceRatioState = priceRatioState;
    }

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        Rounding rounding
    ) external view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                lastVirtualBalances[a],
                lastVirtualBalances[b],
                c,
                lastTimestamp,
                centerednessMargin,
                _priceRatioState,
                rounding
            );
    }

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        Rounding rounding
    ) external pure returns (uint256) {
        return ReClammMath.computeInvariant(balancesScaled18, virtualBalances[a], virtualBalances[b], rounding);
    }

    function computeOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.computeOutGivenIn(
                balancesScaled18,
                virtualBalances[a],
                virtualBalances[b],
                tokenInIndex,
                tokenOutIndex,
                amountGivenScaled18
            );
    }

    function computeInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.computeInGivenOut(
                balancesScaled18,
                virtualBalances[a],
                virtualBalances[b],
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
        returns (uint256[] memory realBalances, uint256[] memory virtualBalances, uint256 fourthRootPriceRatio)
    {
        virtualBalances = new uint256[](2);
        (realBalances, virtualBalances[a], virtualBalances[b], fourthRootPriceRatio) = ReClammMath
            .computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);
    }

    function computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 dailyPriceShiftBase,
        uint32 lastTimestamp,
        uint64 centerednessMargin
    ) external view returns (uint256[] memory newVirtualBalances, bool changed) {
        newVirtualBalances = new uint256[](2);
        (newVirtualBalances[a], newVirtualBalances[b], changed) = ReClammMath.computeCurrentVirtualBalances(
            balancesScaled18,
            virtualBalances[a],
            virtualBalances[b],
            dailyPriceShiftBase,
            lastTimestamp,
            centerednessMargin,
            _priceRatioState
        );
    }

    function isPoolWithinTargetRange(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 centerednessMargin
    ) external pure returns (bool) {
        return
            ReClammMath.isPoolWithinTargetRange(
                balancesScaled18,
                virtualBalances[a],
                virtualBalances[b],
                centerednessMargin
            );
    }

    function computeCenteredness(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) external pure returns (uint256) {
        return ReClammMath.computeCenteredness(balancesScaled18, virtualBalances[a], virtualBalances[b]);
    }

    function computeFourthRootPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) external pure returns (uint96) {
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
        uint256[] memory virtualBalances
    ) external pure returns (bool) {
        return ReClammMath.isAboveCenter(balancesScaled18, virtualBalances[a], virtualBalances[b]);
    }

    function toDailyPriceShiftBase(uint256 dailyPriceShiftExponent) external pure returns (uint256) {
        return ReClammMath.toDailyPriceShiftBase(dailyPriceShiftExponent);
    }

    function toDailyPriceShiftExponent(uint256 dailyPriceShiftBase) external pure returns (uint256) {
        return ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);
    }

    function sqrtScaled18(uint256 value) external pure returns (uint256) {
        return ReClammMath.sqrtScaled18(value);
    }

    function pow4(uint256 rootValue) external pure returns (uint256) {
        return ReClammMath.pow4(rootValue);
    }
}
