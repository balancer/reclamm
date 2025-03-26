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

    /// @dev The swap result is bigger than the real balance of the token.
    error AmountOutBiggerThanBalance();

    /// @dev The swap result is negative due to a rounding issue.
    error NegativeAmountOut();

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

    /**
     * @notice Get the current virtual balances and compute the invariant of the pool using constant product.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalances The last virtual balances, sorted in token registration order
     * @param timeConstant IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param currentTimestamp The current timestamp
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is out of range
     * @param sqrtPriceRatioState A struct containing start and end price ratios and a time interval
     * @param rounding Rounding direction to consider when computing the invariant
     * @return invariant The invariant of the pool.
     */
    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 timeConstant,
        uint32 lastTimestamp,
        uint32 currentTimestamp,
        uint256 centerednessMargin,
        SqrtPriceRatioState storage sqrtPriceRatioState,
        Rounding rounding
    ) internal pure returns (uint256 invariant) {
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

    /**
     * @notice Compute the invariant of the pool using constant product.
     * @dev Notice that the invariant is computed as (x+a)(y+b), without square root. This is because the calculations
     * of virtual balance updates are easier with this invariant. Different from other pools, the invariant of ReClamm
     * will change over time if pool is out of range or price ratio is updating, so the pool is not composable.
     * Therefore, the BPT value is meaningless. Moreover, only add/remove liquidity proportional is supported, which
     * does not require the invariant. So, it does not matter if the invariant and liquidity relation is not linear,
     * and the invariant is used mostly to calculate swaps.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param rounding Rounding direction to consider when computing the invariant
     * @return invariant The invariant of the pool
     */
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

    /**
     * @notice Compute the `amountOut` of tokenOut in a swap, given the current balances and virtual balances.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param tokenInIndex Index of the token being swapped in
     * @param tokenOutIndex Index of the token being swapped out
     * @param amountGivenScaled18 The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return amountCalculatedScaled18 The calculated amount of `tokenOut` returned in an ExactIn swap
     */
    function calculateOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) internal pure returns (uint256 amountCalculatedScaled18) {
        // Round up, so the swapper absorbs rounding imprecisions (rounds in favor of the vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_UP);
        // Total (virtual + real) token out amount that should stay in the pool after the swap.
        uint256 tokenOutPoolAmount = invariant.divUp(
            balancesScaled18[tokenInIndex] + virtualBalances[tokenInIndex] + amountGivenScaled18
        );

        uint256 totalBalancesTokenOut = balancesScaled18[tokenOutIndex] + virtualBalances[tokenOutIndex];

        if (tokenOutPoolAmount > totalBalancesTokenOut) {
            // If the amount of `tokenOut` remaining in the pool post-swap is greater than the total balance of
            // `tokenOut`, that means the swap result is negative due to a rounding issue.
            revert NegativeAmountOut();
        }

        amountCalculatedScaled18 = totalBalancesTokenOut - tokenOutPoolAmount;
        if (amountCalculatedScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be bigger than the real balance of the token.
            revert AmountOutBiggerThanBalance();
        }
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and virtual balances.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param tokenInIndex Index of the token being swapped in
     * @param tokenOutIndex Index of the token being swapped out
     * @param amountGivenScaled18 The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return amountCalculatedScaled18 The calculated amount of `tokenIn` returned in an ExactOut swap
     */
    function calculateInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountGivenScaled18
    ) internal pure returns (uint256) {
        if (amountGivenScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount in cannot be bigger than the real balance of the token.
            revert AmountOutBiggerThanBalance();
        }

        // Round up, so the swapper absorbs rounding imprecisions (rounds in favor of the vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_UP);

        return
            invariant.divUp(balancesScaled18[tokenOutIndex] + virtualBalances[tokenOutIndex] - amountGivenScaled18) -
            balancesScaled18[tokenInIndex] -
            virtualBalances[tokenInIndex];
    }

    /**
     * @notice Calculate the initial virtual balances of the pool.
     * @dev The initial virtual balances are calculated based on the initial sqrt price ratio and the initial balances.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param sqrtPriceRatio The initial sqrt price ratio of the pool
     * @return virtualBalances The initial virtual balances of the pool
     */
    function initializeVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 sqrtPriceRatio
    ) internal pure returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](balancesScaled18.length);
        virtualBalances[0] = balancesScaled18[0].divDown(sqrtPriceRatio - FixedPoint.ONE);
        virtualBalances[1] = balancesScaled18[1].divDown(sqrtPriceRatio - FixedPoint.ONE);
    }

    /**
     * @notice Calculate the current virtual balances of the pool.
     * @dev If the pool is in range or the price ratio is not updating, the virtual balances do not change and
     * lastVirtualBalances are returned. Otherwise, follow these three steps:
     * 1. Calculate the current sqrt price ratio.
     * 2. Shrink/Expand the price interval considering the current sqrt price ratio. (if price ratio is updating)
     * 3. Track the market price by moving the price interval. (if pool is out of range)
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalances The last virtual balances, sorted in token registration order
     * @param timeConstant IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param currentTimestamp The current timestamp
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is out of range
     * @param sqrtPriceRatioState A struct containing start and end price ratios and a time interval
     * @return currentVirtualBalances The current virtual balances of the pool
     * @return changed Whether the virtual balances have changed and must be updated in the pool
     */
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

        uint256 currentSqrtPriceRatio = calculateSqrtPriceRatio(
            currentTimestamp,
            _sqrtPriceRatioState.startSqrtPriceRatio,
            _sqrtPriceRatioState.endSqrtPriceRatio,
            _sqrtPriceRatioState.startTime,
            _sqrtPriceRatioState.endTime
        );

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

        // If the price ratio is updating, update
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
