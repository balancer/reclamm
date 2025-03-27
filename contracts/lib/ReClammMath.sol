// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { LogExpMath } from "@balancer-labs/v3-solidity-utils/contracts/math/LogExpMath.sol";

struct PriceRatioState {
    uint96 startFourthRootPriceRatio;
    uint96 endFourthRootPriceRatio;
    uint32 startTime;
    uint32 endTime;
}

library ReClammMath {
    using FixedPoint for uint256;

    /// @dev The swap result is bigger than the real balance of the token.
    error AmountOutBiggerThanBalance();

    /// @dev The swap result is negative due to a rounding issue.
    error NegativeAmountOut();

    /// @dev The last timestamp is greater than the current timestamp.
    error LastTimestampGreaterThanCurrentTimestamp();

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
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState,
        Rounding rounding
    ) internal pure returns (uint256 invariant) {
        (uint256[] memory currentVirtualBalances, ) = getCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalances,
            timeConstant,
            lastTimestamp,
            currentTimestamp,
            centerednessMargin,
            priceRatioState
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
     * @param amountInScaled18 The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return amountOutScaled18 The calculated amount of `tokenOut` returned in an ExactIn swap
     */
    function calculateOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountInScaled18
    ) internal pure returns (uint256 amountOutScaled18) {
        // Round up, so the swapper absorbs rounding imprecisions (rounds in favor of the vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_UP);
        // Total (virtual + real) token out amount that should stay in the pool after the swap. Rounding division up,
        // which will round the token out amount down, favoring the vault.
        uint256 tokenOutPoolAmount = invariant.divUp(
            balancesScaled18[tokenInIndex] + virtualBalances[tokenInIndex] + amountInScaled18
        );

        uint256 totalBalancesTokenOut = balancesScaled18[tokenOutIndex] + virtualBalances[tokenOutIndex];

        if (tokenOutPoolAmount > totalBalancesTokenOut) {
            // If the amount of `tokenOut` remaining in the pool post-swap is greater than the total balance of
            // `tokenOut`, that means the swap result is negative due to a rounding issue.
            revert NegativeAmountOut();
        }

        amountOutScaled18 = totalBalancesTokenOut - tokenOutPoolAmount;
        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
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
     * @param amountOutScaled18 The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return amountInScaled18 The calculated amount of `tokenIn` returned in an ExactOut swap
     */
    function calculateInGivenOut(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountOutScaled18
    ) internal pure returns (uint256 amountInScaled18) {
        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be bigger than the real balance of the token in the pool.
            revert AmountOutBiggerThanBalance();
        }

        // Round up, so the swapper absorbs rounding imprecisions (rounds in favor of the vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_UP);

        // Rounding division up, which will round the token in amount up, favoring the vault.
        amountInScaled18 =
            invariant.divUp(balancesScaled18[tokenOutIndex] + virtualBalances[tokenOutIndex] - amountOutScaled18) -
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
        uint256 fourthRootPriceRatio
    ) internal pure returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](balancesScaled18.length);
        virtualBalances[0] = balancesScaled18[0].divDown(fourthRootPriceRatio - FixedPoint.ONE);
        virtualBalances[1] = balancesScaled18[1].divDown(fourthRootPriceRatio - FixedPoint.ONE);
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
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState
    ) internal pure returns (uint256[] memory currentVirtualBalances, bool changed) {
        // TODO Review rounding

        if (lastTimestamp > currentTimestamp) {
            // The last timestamp should be in the past, so the current timestamp must always be equal or greater than
            // last timestamp.
            revert LastTimestampGreaterThanCurrentTimestamp();
        }

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (lastVirtualBalances, false);
        }

        currentVirtualBalances = lastVirtualBalances;

        PriceRatioState memory _priceRatioState = priceRatioState;

        uint256 currentFourthRootPriceRatio = calculateFourthRootPriceRatio(
        uint256 currentSqrtPriceRatio = calculateSqrtPriceRatio(
            currentTimestamp,
            _priceRatioState.startFourthRootPriceRatio,
            _priceRatioState.endFourthRootPriceRatio,
            _priceRatioState.startTime,
            _priceRatioState.endTime
        );

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

        // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
        if (
            _priceRatioState.startTime != 0 &&
            currentTimestamp > _priceRatioState.startTime &&
            lastTimestamp < _priceRatioState.endTime
            _sqrtPriceRatioState.startTime != 0 &&
            currentTimestamp > _sqrtPriceRatioState.startTime &&
            lastTimestamp < _sqrtPriceRatioState.endTime
        ) {
            currentVirtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
                currentFourthRootPriceRatio,
                balancesScaled18,
                lastVirtualBalances,
                isPoolAboveCenter
            );

            changed = true;
        }

        // If the pool is out of range, track the market price by moving the price interval.
        if (isPoolInRange(balancesScaled18, currentVirtualBalances, centerednessMargin) == false) {
            currentVirtualBalances = calculateVirtualBalancesOutOfRange(
                currentFourthRootPriceRatio,
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

    /**
     * @notice Calculate the virtual balances of the pool when the price ratio is updating.
     * @dev This function uses a Bhaskara formula to shrink/expand the price interval by recalculating the virtual
     * balances. It'll keep the pool centeredness constant and track the desired price ratio. To reach this formula,
     * we need to solve the following equations:
     *
     * 1. centeredness = (Ra * Vb) / (Rb * Va)
     * 2. PriceRatio = invariant^2/(Va * Vb)^2 (maxPrice / minPrice)
     * 3. invariant = (Va + Ra) * (Vb + Rb)
     *
     * Replace [3] in [2]. Then, isolate one of the V's. Replace the isolated V in [1]. You will get a quadratic
     * equation, used in this function.
     *
     * @param currentSqrtPriceRatio The current sqrt price ratio of the pool
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalances The last virtual balances, sorted in token registration order
     * @param isPoolAboveCenter Whether the pool is above or below the center
     * @return virtualBalances The new virtual balances of the pool
     */
    function calculateVirtualBalancesUpdatingPriceRatio(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        bool isPoolAboveCenter
    ) internal pure returns (uint256[] memory virtualBalances) {
        // The token overvalued is the one with low token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);
        uint256 balanceTokenUndervalued = balancesScaled18[indexTokenUndervalued];
        uint256 balanceTokenOvervalued = balancesScaled18[indexTokenOvervalued];

        virtualBalances = new uint256[](2);

        // Calculate the current pool centeredness, which will remain constant.
        uint256 poolCenteredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

        // Terms of quadratic equation.
        uint256 a = currentSqrtPriceRatio.mulDown(currentSqrtPriceRatio) - FixedPoint.ONE;
        uint256 b = balanceTokenUndervalued.mulDown(FixedPoint.ONE + poolCenteredness);
        uint256 c = balanceTokenUndervalued.mulDown(balanceTokenUndervalued).mulDown(poolCenteredness);

        uint256 virtualBalanceUndervalued = (b + Math.sqrt((b.mulDown(b) + 4 * a.mulDown(c)) * FixedPoint.ONE)).divDown(
            2 * a
        );
        // Avoid using FixedPoint math to improve the precision of the result.
        virtualBalances[indexTokenOvervalued] = ((balanceTokenOvervalued * virtualBalanceUndervalued) /
            balanceTokenUndervalued).divDown(poolCenteredness);
        virtualBalances[indexTokenUndervalued] = virtualBalanceUndervalued;
    }

    /**
     * @notice Calculate the virtual balances of the pool when the pool is out of range.
     * @dev This function will track the market price by moving the price interval. It will increase the pool
     * centeredness and change the token prices.
     *
     * @param currentSqrtPriceRatio The current sqrt price ratio of the pool
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param isPoolAboveCenter Whether the pool is above or below the center
     * @param timeConstant IncreaseDayRate divided by 124649
     * @param currentTimestamp The current timestamp
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @return virtualBalances The new virtual balances of the pool
     */
    function calculateVirtualBalancesOutOfRange(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        bool isPoolAboveCenter,
        uint256 timeConstant,
        uint32 currentTimestamp,
        uint32 lastTimestamp
    ) internal pure returns (uint256[] memory) {
        uint256 priceRatio = currentFourthRootPriceRatio.mulDown(currentFourthRootPriceRatio);

        // The token overvalued is the one with low token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);

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

    /**
     * @notice Check if the pool is in range.
     * @dev The pool is in range if the centeredness is greater than the centeredness margin.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is out of range
     * @return isInRange Whether the pool is in range
     */
    function isPoolInRange(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        uint256 centerednessMargin
    ) internal pure returns (bool) {
        uint256 centeredness = calculateCenteredness(balancesScaled18, virtualBalances);
        return centeredness >= centerednessMargin;
    }

    /**
     * @notice Calculate the centeredness of the pool.
     * @dev The centeredness is calculated as the ratio of the real balances divided by the ratio of the virtual
     * balances. It's a number between 0 and 100%, where 100% means that the token prices are centered and 0%
     * means that the token prices are at the edge of the price interval.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @return poolCenteredness The centeredness of the pool
     */
    function calculateCenteredness(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) internal pure returns (uint256) {
        if (balancesScaled18[0] == 0 || balancesScaled18[1] == 0) {
            return 0;
        }

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, virtualBalances);

        // The token overvalued is the one with low token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);

        return
            ((balancesScaled18[indexTokenOvervalued] * virtualBalances[indexTokenUndervalued]) /
                balancesScaled18[indexTokenUndervalued]).divDown(virtualBalances[indexTokenOvervalued]);
    }

    /**
     * @notice Calculate the sqrt price ratio of the pool.
     * @dev This function will interpolate the sqrt price ratio of the pool based on the current time, the start and
     * end sqrt price ratios and the start and end times.
     *
     * @param currentTime The current timestamp
     * @param startSqrtPriceRatio The start sqrt price ratio of the pool
     * @param endSqrtPriceRatio The end sqrt price ratio of the pool
     * @param startTime The timestamp of the last user interaction with the pool
     * @param endTime The timestamp of the next user interaction with the pool
     * @return sqrtPriceRatio The sqrt price ratio of the pool
     */
    function calculateSqrtPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) internal pure returns (uint96) {
        if (currentTime <= startTime) {
            return startFourthRootPriceRatio;
        } else if (currentTime >= endTime) {
            return endFourthRootPriceRatio;
        } else if (startFourthRootPriceRatio == endFourthRootPriceRatio) {
            return endFourthRootPriceRatio;
        }

        uint256 exponent = uint256(currentTime - startTime).divDown(endTime - startTime);

        return
            SafeCast.toUint96(
                uint256(startFourthRootPriceRatio).mulDown(LogExpMath.pow(endFourthRootPriceRatio, exponent)).divDown(
                    LogExpMath.pow(startFourthRootPriceRatio, exponent)
                )
            );
    }

    /**
     * @notice Check if the pool is above center.
     * @dev The pool is above center if the ratio of the real balances is greater than the ratio of the virtual
     * balances.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @return isAboveCenter Whether the pool is above center
     */
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

    /**
     * @notice Parse the price shift daily rate to a time constant.
     * @param priceShiftDailyRate The price shift daily rate
     * @return timeConstant The time constant
     */
    function parsePriceShiftDailyRate(uint256 priceShiftDailyRate) internal pure returns (uint128) {
        // Divide daily rate by a number of seconds per day (plus some adjustment)
        return SafeCast.toUint128(priceShiftDailyRate / _SECONDS_PER_DAY_WITH_ADJUSTMENT);
    }
}
