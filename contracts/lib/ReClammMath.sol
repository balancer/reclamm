// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { LogExpMath } from "@balancer-labs/v3-solidity-utils/contracts/math/LogExpMath.sol";

struct SqrtQ0State {
    uint96 startSqrtQ0;
    uint96 endSqrtQ0;
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
        uint256 c,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtQ0State storage sqrtQ0State,
        Rounding rounding
    ) internal pure returns (uint256) {
        (uint256[] memory virtualBalances, ) = getVirtualBalances(
            balancesScaled18,
            lastVirtualBalances,
            c,
            lastTimestamp,
            currentTimestamp,
            centerednessMargin,
            sqrtQ0State
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
        uint256[] memory finalBalances = new uint256[](balancesScaled18.length);

        finalBalances[0] = balancesScaled18[0] + virtualBalances[0];
        finalBalances[1] = balancesScaled18[1] + virtualBalances[1];

        uint256 invariant = finalBalances[0].mulUp(finalBalances[1]);

        uint256 amountOut = finalBalances[tokenOutIndex] -
            invariant.divUp(finalBalances[tokenInIndex] + amountGivenScaled18);

        // The swap result should not be bigger than the real balance of the token out.
        return amountOut > balancesScaled18[tokenOutIndex] ? balancesScaled18[tokenOutIndex] : amountOut;
    }

    function calculateInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) internal pure returns (uint256) {
        uint256[] memory finalBalances = new uint256[](balancesScaled18.length);

        finalBalances[0] = balancesScaled18[0] + virtualBalances[0];
        finalBalances[1] = balancesScaled18[1] + virtualBalances[1];

        uint256 invariant = finalBalances[0].mulUp(finalBalances[1]);

        return invariant.divUp(finalBalances[tokenOutIndex] - amountGivenScaled18) - finalBalances[tokenInIndex];
    }

    function initializeVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 sqrtQ0
    ) internal pure returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](balancesScaled18.length);
        virtualBalances[0] = balancesScaled18[0].divDown(sqrtQ0 - FixedPoint.ONE);
        virtualBalances[1] = balancesScaled18[1].divDown(sqrtQ0 - FixedPoint.ONE);
    }

    function getVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 c,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtQ0State storage sqrtQ0State
    ) internal pure returns (uint256[] memory virtualBalances, bool changed) {
        // TODO Review rounding

        virtualBalances = lastVirtualBalances;

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (virtualBalances, false);
        }

        SqrtQ0State memory _sqrtQ0State = sqrtQ0State;

        // Calculate currentSqrtQ0
        uint256 currentSqrtQ0 = calculateSqrtQ0(
            currentTimestamp,
            _sqrtQ0State.startSqrtQ0,
            _sqrtQ0State.endSqrtQ0,
            _sqrtQ0State.startTime,
            _sqrtQ0State.endTime
        );

        if (
            _sqrtQ0State.startTime != 0 &&
            currentTimestamp > _sqrtQ0State.startTime &&
            (currentTimestamp < _sqrtQ0State.endTime || lastTimestamp < _sqrtQ0State.endTime)
        ) {
            uint256 lastSqrtQ0 = calculateSqrtQ0(
                lastTimestamp,
                _sqrtQ0State.startSqrtQ0,
                _sqrtQ0State.endSqrtQ0,
                _sqrtQ0State.startTime,
                _sqrtQ0State.endTime
            );

            // Ra_center = Va * (lastSqrtQ0 - 1)
            uint256 rACenter = lastVirtualBalances[0].mulDown(lastSqrtQ0 - FixedPoint.ONE);

            // Va = Ra_center / (currentSqrtQ0 - 1)
            virtualBalances[0] = rACenter.divDown(currentSqrtQ0 - FixedPoint.ONE);

            uint256 currentInvariant = computeInvariant(balancesScaled18, lastVirtualBalances, Rounding.ROUND_DOWN);

            // Vb = currentInvariant / (currentQ0 * Va)
            virtualBalances[1] = currentInvariant.divDown(
                currentSqrtQ0.mulDown(currentSqrtQ0).mulDown(virtualBalances[0])
            );

            changed = true;
        }

        if (isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin) == false) {
            uint256 q0 = currentSqrtQ0.mulDown(currentSqrtQ0);

            if (isAboveCenter(balancesScaled18, lastVirtualBalances)) {
                virtualBalances[1] = lastVirtualBalances[1].mulDown(
                    LogExpMath.pow(FixedPoint.ONE - c, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
                );
                // Va = (Ra * (Vb + Rb)) / (((Q0 - 1) * Vb) - Rb)
                virtualBalances[0] = (balancesScaled18[0].mulDown(virtualBalances[1] + balancesScaled18[1])).divDown(
                    (q0 - FixedPoint.ONE).mulDown(virtualBalances[1]) - balancesScaled18[1]
                );
            } else {
                virtualBalances[0] = lastVirtualBalances[0].mulDown(
                    LogExpMath.pow(FixedPoint.ONE - c, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
                );
                // Vb = (Rb * (Va + Ra)) / (((Q0 - 1) * Va) - Ra)
                virtualBalances[1] = (balancesScaled18[1].mulDown(virtualBalances[0] + balancesScaled18[0])).divDown(
                    (q0 - FixedPoint.ONE).mulDown(virtualBalances[0]) - balancesScaled18[0]
                );
            }

            changed = true;
        }
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
                balancesScaled18[1].mulDown(virtualBalances[0]).divDown(
                    balancesScaled18[0].mulDown(virtualBalances[1])
                );
        } else {
            return
                balancesScaled18[0].mulDown(virtualBalances[1]).divDown(
                    balancesScaled18[1].mulDown(virtualBalances[0])
                );
        }
    }

    function calculateSqrtQ0(
        uint32 currentTime,
        uint96 startSqrtQ0,
        uint96 endSqrtQ0,
        uint32 startTime,
        uint32 endTime
    ) internal pure returns (uint96) {
        if (currentTime <= startTime) {
            return startSqrtQ0;
        } else if (currentTime >= endTime) {
            return endSqrtQ0;
        } else if (startSqrtQ0 == endSqrtQ0) {
            return endSqrtQ0;
        }

        uint256 exponent = uint256(currentTime - startTime).divDown(endTime - startTime);

        return
            SafeCast.toUint96(
                uint256(startSqrtQ0).mulDown(LogExpMath.pow(endSqrtQ0, exponent)).divDown(
                    LogExpMath.pow(startSqrtQ0, exponent)
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
