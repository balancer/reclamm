// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { LogExpMath } from "@balancer-labs/v3-solidity-utils/contracts/math/LogExpMath.sol";

struct SqrtPriceRatioState {
    uint96 startSqrtPriceRatio;
    uint96 endSqrtPriceRatio;
    uint32 startTime;
    uint32 endTime;
}

library ReClammMath {
    using FixedPoint for uint256;

    // We want, after 1 day (86400 seconds) that the pool is out of range, to double the price (or reduce by 50%)
    // with PriceShiftDailyRate = 100%. So, we want to be able to move the virtual balances by the same rate.
    // Therefore, after one day:
    //
    // 1. `Vnext = 2*Vcurrent`
    // 2. In the equation `Vnext = Vcurrent * (1 - tau)^(n+1)`, isolate tau.
    // 3. Replace `Vnext` with `2*Vcurrent` and `n` with `86400` to get `tau = 1 - pow(2, 1/(86400+1))`.
    // 4. Since `tau = priceShiftDailyRate/x`, then `x = priceShiftDailyRate/tau`. Since priceShiftDailyRate = 100%,
    //    then `x = 100%/(1 - pow(2, 1/(86400+1)))`, which is 124649.
    uint256 private constant _SECONDS_PER_DAY_WITH_ADJUSTMENT = 124649;

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 timeConstant,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState storage sqrtPriceRatioState,
        Rounding rounding
    ) internal pure returns (uint256) {
        (uint256[] memory currentVirtualBalances, ) = getCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalances,
            timeConstant,
            lastTimestamp,
            currentTimestamp,
            centerednessMargin,
            sqrtPriceRatioState
        );

        return computeInvariant(balancesScaled18, currentVirtualBalances, rounding);
    }

    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        Rounding rounding
    ) internal pure returns (uint256) {
        function(uint256, uint256) pure returns (uint256) _mulUpOrDown = rounding == Rounding.ROUND_DOWN
            ? FixedPoint.mulDown
            : FixedPoint.mulUp;

        return _mulUpOrDown((balancesScaled18[0] + virtualBalances[0]), (balancesScaled18[1] + virtualBalances[1]));
    }

    function calculateOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) internal pure returns (uint256) {
        uint256[] memory totalBalances = new uint256[](balancesScaled18.length);

        totalBalances[0] = balancesScaled18[0] + virtualBalances[0];
        totalBalances[1] = balancesScaled18[1] + virtualBalances[1];

        uint256 invariant = totalBalances[0].mulUp(totalBalances[1]);
        // Total (virtual + real) token out amount that should stay in the pool after the swap.
        uint256 tokenOutPoolAmount = invariant.divUp(totalBalances[tokenInIndex] + amountGivenScaled18);

        if (tokenOutPoolAmount > totalBalances[tokenOutIndex]) {
            // If the amount of `tokenOut` remaining in the pool post-swap is greater than the total balance of
            // `tokenOut`, that means the pool is heavily unbalanced, and `tokenIn` is extremely undervalued.
            // Set the swap result to 0 in this case.
            return 0;
        }

        return totalBalances[tokenOutIndex] - tokenOutPoolAmount;
    }

    function calculateInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) internal pure returns (uint256) {
        uint256[] memory totalBalances = new uint256[](balancesScaled18.length);

        totalBalances[0] = balancesScaled18[0] + virtualBalances[0];
        totalBalances[1] = balancesScaled18[1] + virtualBalances[1];

        uint256 invariant = totalBalances[0].mulUp(totalBalances[1]);

        return invariant.divUp(totalBalances[tokenOutIndex] - amountGivenScaled18) - totalBalances[tokenInIndex];
    }

    function initializeVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 sqrtPriceRatio
    ) internal pure returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](balancesScaled18.length);
        virtualBalances[0] = balancesScaled18[0].divDown(sqrtPriceRatio - FixedPoint.ONE);
        virtualBalances[1] = balancesScaled18[1].divDown(sqrtPriceRatio - FixedPoint.ONE);
    }

    function getCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 timeConstant,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState storage sqrtPriceRatioState
    ) internal pure returns (uint256[] memory currentVirtualBalances, bool changed) {
        // TODO Review rounding

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (lastVirtualBalances, false);
        }

        currentVirtualBalances = lastVirtualBalances;

        SqrtPriceRatioState memory _sqrtPriceRatioState = sqrtPriceRatioState;

        // Calculate currentSqrtPriceRatio
        uint256 currentSqrtPriceRatio = calculateSqrtPriceRatio(
            currentTimestamp,
            _sqrtPriceRatioState.startSqrtPriceRatio,
            _sqrtPriceRatioState.endSqrtPriceRatio,
            _sqrtPriceRatioState.startTime,
            _sqrtPriceRatioState.endTime
        );

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

        if (
            _sqrtPriceRatioState.startTime != 0 &&
            currentTimestamp > _sqrtPriceRatioState.startTime &&
            (currentTimestamp < _sqrtPriceRatioState.endTime || lastTimestamp < _sqrtPriceRatioState.endTime)
        ) {
            currentVirtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
                currentSqrtPriceRatio,
                balancesScaled18,
                lastVirtualBalances,
                isPoolAboveCenter
            );

            changed = true;
        }

        if (isPoolInRange(balancesScaled18, currentVirtualBalances, centerednessMargin) == false) {
            currentVirtualBalances = calculateVirtualBalancesOutOfRange(
                currentSqrtPriceRatio,
                balancesScaled18,
                currentVirtualBalances,
                isPoolAboveCenter,
                timeConstant,
                currentTimestamp,
                lastTimestamp
            );

            changed = true;
        }
    }

    function calculateVirtualBalancesUpdatingPriceRatio(
        uint256 currentSqrtPriceRatio,
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        bool isPoolAboveCenter
    ) internal pure returns (uint256[] memory virtualBalances) {
        uint256 indexTokenUndervalued = isPoolAboveCenter ? 0 : 1;
        uint256 indexTokenOvervalued = isPoolAboveCenter ? 1 : 0;

        virtualBalances = new uint256[](2);

        uint256 poolCenteredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

        uint256 a = currentSqrtPriceRatio.mulDown(currentSqrtPriceRatio) - FixedPoint.ONE;
        uint256 b = balancesScaled18[indexTokenUndervalued].mulDown(FixedPoint.ONE + poolCenteredness);
        uint256 c = balancesScaled18[indexTokenUndervalued].mulDown(balancesScaled18[indexTokenUndervalued]).mulDown(
            poolCenteredness
        );
        virtualBalances[indexTokenUndervalued] = (b + Math.sqrt((b.mulDown(b) + 4 * a.mulDown(c)) * FixedPoint.ONE))
            .divDown(2 * a);
        virtualBalances[indexTokenOvervalued] = (
            balancesScaled18[indexTokenOvervalued].mulDown(virtualBalances[indexTokenUndervalued])
        ).divDown(balancesScaled18[indexTokenUndervalued]).divDown(poolCenteredness);
    }

    function calculateVirtualBalancesOutOfRange(
        uint256 currentSqrtPriceRatio,
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        bool isPoolAboveCenter,
        uint256 timeConstant,
        uint32 currentTimestamp,
        uint32 lastTimestamp
    ) internal pure returns (uint256[] memory) {
        uint256 priceRatio = currentSqrtPriceRatio.mulDown(currentSqrtPriceRatio);

        uint256 indexTokenUndervalued = isPoolAboveCenter ? 0 : 1;
        uint256 indexTokenOvervalued = isPoolAboveCenter ? 1 : 0;

        // Vb = Vb * (1 - timeConstant)^(Tcurr - Tlast)
        virtualBalances[indexTokenOvervalued] = virtualBalances[indexTokenOvervalued].mulDown(
            LogExpMath.pow(FixedPoint.ONE - timeConstant, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
        );
        // Va = (Ra * (Vb + Rb)) / (((priceRatio - 1) * Vb) - Rb)
        virtualBalances[indexTokenUndervalued] = (
            balancesScaled18[indexTokenUndervalued].mulDown(
                virtualBalances[indexTokenOvervalued] + balancesScaled18[indexTokenOvervalued]
            )
        ).divDown(
                (priceRatio - FixedPoint.ONE).mulDown(virtualBalances[indexTokenOvervalued]) -
                    balancesScaled18[indexTokenOvervalued]
            );

        return virtualBalances;
    }

    function isPoolInRange(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 centerednessMargin
    ) internal pure returns (bool) {
        uint256 centeredness = calculateCenteredness(balancesScaled18, virtualBalances);
        return centeredness >= centerednessMargin;
    }

    function calculateCenteredness(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) internal pure returns (uint256) {
        if (balancesScaled18[0] == 0 || balancesScaled18[1] == 0) {
            return 0;
        } else if (isAboveCenter(balancesScaled18, virtualBalances)) {
            return
                balancesScaled18[1].mulDown(virtualBalances[0]).divDown(balancesScaled18[0]).divDown(
                    virtualBalances[1]
                );
        } else {
            return
                balancesScaled18[0].mulDown(virtualBalances[1]).divDown(balancesScaled18[1]).divDown(
                    virtualBalances[0]
                );
        }
    }

    function calculateSqrtPriceRatio(
        uint32 currentTime,
        uint96 startSqrtPriceRatio,
        uint96 endSqrtPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) internal pure returns (uint96) {
        if (currentTime <= startTime) {
            return startSqrtPriceRatio;
        } else if (currentTime >= endTime) {
            return endSqrtPriceRatio;
        } else if (startSqrtPriceRatio == endSqrtPriceRatio) {
            return endSqrtPriceRatio;
        }

        uint256 exponent = uint256(currentTime - startTime).divDown(endTime - startTime);

        return
            SafeCast.toUint96(
                uint256(startSqrtPriceRatio).mulDown(LogExpMath.pow(endSqrtPriceRatio, exponent)).divDown(
                    LogExpMath.pow(startSqrtPriceRatio, exponent)
                )
            );
    }

    function isAboveCenter(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) internal pure returns (bool) {
        if (balancesScaled18[1] == 0) {
            return true;
        } else {
            return balancesScaled18[0].divDown(balancesScaled18[1]) > virtualBalances[0].divDown(virtualBalances[1]);
        }
    }

    function parseIncreaseDayRate(uint256 increaseDayRate) internal pure returns (uint256) {
        // Divide daily rate by a number of seconds per day (plus some adjustment)
        return increaseDayRate / _SECONDS_PER_DAY_WITH_ADJUSTMENT;
    }
}
