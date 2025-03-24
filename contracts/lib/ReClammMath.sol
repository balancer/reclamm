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

    // Constant to increase the price by a factor 2 if increase rate is 100%.
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
        (uint256[] memory virtualBalances, ) = getVirtualBalances(
            balancesScaled18,
            lastVirtualBalances,
            timeConstant,
            lastTimestamp,
            currentTimestamp,
            centerednessMargin,
            sqrtPriceRatioState
        );

        return computeInvariant(balancesScaled18, virtualBalances, rounding);
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
            // If the token out pool amount is greater than the total balance of the token out, it means that the pool
            // is heavily unbalanced and the token in is deeply undervalued. The swap result must be 0 in this case.
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

    function getVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 timeConstant,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState storage sqrtPriceRatioState
    ) internal pure returns (uint256[] memory virtualBalances, bool changed) {
        // TODO Review rounding

        virtualBalances = lastVirtualBalances;

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (virtualBalances, false);
        }

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
            virtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
                currentSqrtPriceRatio,
                balancesScaled18,
                lastVirtualBalances,
                isPoolAboveCenter
            );

            changed = true;
        }

        if (isPoolInRange(balancesScaled18, virtualBalances, centerednessMargin) == false) {
            virtualBalances = calculateVirtualBalancesOutOfRange(
                currentSqrtPriceRatio,
                balancesScaled18,
                virtualBalances,
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
        virtualBalances = new uint256[](2);

        uint256 poolCenteredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

        if (isPoolAboveCenter) {
            uint256 a = currentSqrtPriceRatio.mulDown(currentSqrtPriceRatio) - FixedPoint.ONE;
            uint256 b = balancesScaled18[0].mulDown(FixedPoint.ONE + poolCenteredness);
            uint256 c = balancesScaled18[0].mulDown(balancesScaled18[0]).mulDown(poolCenteredness);
            virtualBalances[0] = (b + Math.sqrt((b.mulDown(b) + 4 * a.mulDown(c)) * FixedPoint.ONE)).divDown(2 * a);
            virtualBalances[1] = (balancesScaled18[1].mulDown(virtualBalances[0])).divDown(balancesScaled18[0]).divDown(
                poolCenteredness
            );
        } else {
            uint256 a = currentSqrtPriceRatio.mulDown(currentSqrtPriceRatio) - FixedPoint.ONE;
            uint256 b = balancesScaled18[1].mulDown(FixedPoint.ONE + poolCenteredness);
            uint256 c = balancesScaled18[1].mulDown(balancesScaled18[1]).mulDown(poolCenteredness);
            virtualBalances[1] = (b + Math.sqrt((b.mulDown(b) + 4 * a.mulDown(c)) * FixedPoint.ONE)).divDown(2 * a);
            virtualBalances[0] = (balancesScaled18[0].mulDown(virtualBalances[1])).divDown(balancesScaled18[1]).divDown(
                poolCenteredness
            );
        }
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

        if (isPoolAboveCenter) {
            virtualBalances[1] = virtualBalances[1].mulDown(
                LogExpMath.pow(FixedPoint.ONE - timeConstant, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
            );
            // Va = (Ra * (Vb + Rb)) / (((priceRatio - 1) * Vb) - Rb)
            virtualBalances[0] = (balancesScaled18[0].mulDown(virtualBalances[1] + balancesScaled18[1])).divDown(
                (priceRatio - FixedPoint.ONE).mulDown(virtualBalances[1]) - balancesScaled18[1]
            );
        } else {
            virtualBalances[0] = virtualBalances[0].mulDown(
                LogExpMath.pow(FixedPoint.ONE - timeConstant, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
            );
            // Vb = (Rb * (Va + Ra)) / (((priceRatio - 1) * Va) - Ra)
            virtualBalances[1] = (balancesScaled18[1].mulDown(virtualBalances[0] + balancesScaled18[0])).divDown(
                (priceRatio - FixedPoint.ONE).mulDown(virtualBalances[0]) - balancesScaled18[0]
            );
        }

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
