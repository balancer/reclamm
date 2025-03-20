// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { SqrtPriceRatioState, ReClammMath } from "../lib/ReClammMath.sol";

contract ReClammMathMock {
    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint256 lastTimestamp,
        uint256 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState memory sqrtPriceRatioState,
        Rounding rounding
    ) external pure returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                lastVirtualBalances,
                c,
                lastTimestamp,
                currentTimestamp,
                centerednessMargin,
                sqrtPriceRatioState,
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
        uint256 sqrtPriceRatio
    ) external pure returns (uint256[] memory virtualBalances) {
        return ReClammMath.initializeVirtualBalances(balancesScaled18, sqrtPriceRatio);
    }

    function getVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint256 lastTimestamp,
        uint256 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState memory sqrtPriceRatioState
    ) external pure returns (uint256[] memory virtualBalances, bool changed) {
        return
            ReClammMath.getVirtualBalances(
                balancesScaled18,
                lastVirtualBalances,
                c,
                lastTimestamp,
                currentTimestamp,
                centerednessMargin,
                sqrtPriceRatioState
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

    function calculateSqrtPriceRatio(
        uint256 currentTime,
        uint256 startSqrtPriceRatio,
        uint256 endSqrtPriceRatio,
        uint256 startTime,
        uint256 endTime
    ) external pure returns (uint256) {
        return
            ReClammMath.calculateSqrtPriceRatio(
                currentTime,
                startSqrtPriceRatio,
                endSqrtPriceRatio,
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

    function parseIncreaseDayRate(uint256 increaseDayRate) external pure returns (uint256) {
        return ReClammMath.parseIncreaseDayRate(increaseDayRate);
    }
}
