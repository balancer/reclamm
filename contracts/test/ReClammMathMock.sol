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
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        Rounding rounding
    ) external view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                lastVirtualBalances,
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
        return ReClammMath.computeInvariant(balancesScaled18, virtualBalances, rounding);
    }

    function calculateOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.calculateOutGivenIn(
                balancesScaled18,
                virtualBalances,
                tokenInIndex,
                tokenOutIndex,
                amountGivenScaled18
            );
    }

    function calculateInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) external pure returns (uint256) {
        return
            ReClammMath.calculateInGivenOut(
                balancesScaled18,
                virtualBalances,
                tokenInIndex,
                tokenOutIndex,
                amountGivenScaled18
            );
    }

    function initializeVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 fourthRootPriceRatio
    ) external pure returns (uint256[] memory virtualBalances) {
        return ReClammMath.initializeVirtualBalances(balancesScaled18, fourthRootPriceRatio);
    }

    function getCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint32 lastTimestamp,
        uint64 centerednessMargin
    ) external view returns (uint256[] memory virtualBalances, bool changed) {
        return
            ReClammMath.getCurrentVirtualBalances(
                balancesScaled18,
                lastVirtualBalances,
                c,
                lastTimestamp,
                centerednessMargin,
                _priceRatioState
            );
    }

    function isPoolInRange(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 centerednessMargin
    ) external pure returns (bool) {
        return ReClammMath.isPoolInRange(balancesScaled18, virtualBalances, centerednessMargin);
    }

    function calculateCenteredness(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) external pure returns (uint256) {
        return ReClammMath.calculateCenteredness(balancesScaled18, virtualBalances);
    }

    function calculateFourthRootPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) external pure returns (uint256) {
        return
            ReClammMath.calculateFourthRootPriceRatio(
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
        return ReClammMath.isAboveCenter(balancesScaled18, virtualBalances);
    }

    function computePriceShiftDailyRate(uint256 priceShiftDailyRate) external pure returns (uint256) {
        return ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);
    }
}
