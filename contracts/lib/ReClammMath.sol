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
    uint32 priceRatioUpdateStartTime;
    uint32 priceRatioUpdateEndTime;
}

library ReClammMath {
    using FixedPoint for uint256;
    using SafeCast for *;

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
     * @param priceShiftDailyRangeInSeconds IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param centerednessMargin A symmetrical measure of how closely an unbalanced pool can approach the limits of the
     * price range before it is considered out of range
     * @param priceRatioState A struct containing start and end price ratios and a time interval
     * @param rounding Rounding direction to consider when computing the invariant
     * @return invariant The invariant of the pool
     */
    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 priceShiftDailyRangeInSeconds,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState,
        Rounding rounding
    ) internal view returns (uint256 invariant) {
        (uint256[] memory currentVirtualBalances, ) = getCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalances,
            priceShiftDailyRangeInSeconds,
            lastTimestamp,
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
        uint256 newTotalTokenOutPoolBalance = invariant.divUp(
            balancesScaled18[tokenInIndex] + virtualBalances[tokenInIndex] + amountInScaled18
        );

        uint256 currentTotalTokenOutPoolBalance = balancesScaled18[tokenOutIndex] + virtualBalances[tokenOutIndex];

        if (newTotalTokenOutPoolBalance > currentTotalTokenOutPoolBalance) {
            // If the amount of `tokenOut` remaining in the pool post-swap is greater than the total balance of
            // `tokenOut`, that means the swap result is negative due to a rounding issue.
            revert NegativeAmountOut();
        }

        amountOutScaled18 = currentTotalTokenOutPoolBalance - newTotalTokenOutPoolBalance;
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
     * @dev The initial virtual balances are calculated based on the initial fourth root of price ratio and the
     * initial balances.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param fourthRootPriceRatio The initial fourth root of price ratio of the pool
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
     * 1. Calculate the current fourth root of price ratio.
     * 2. Shrink/Expand the price interval considering the current fourth root of price ratio. (if price ratio is
     *    updating)
     * 3. Track the market price by moving the price interval. (if pool is out of range)
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalances The last virtual balances, sorted in token registration order
     * @param priceShiftDailyRangeInSeconds IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is out of range
     * @param priceRatioState A struct containing start and end price ratios and a time interval
     * @return currentVirtualBalances The current virtual balances of the pool
     * @return changed Whether the virtual balances have changed and must be updated in the pool
     */
    function getCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256[] memory lastVirtualBalances,
        uint256 priceShiftDailyRangeInSeconds,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState
    ) internal view returns (uint256[] memory currentVirtualBalances, bool changed) {
        uint32 currentTimestamp = block.timestamp.toUint32();

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (lastVirtualBalances, false);
        }

        currentVirtualBalances = lastVirtualBalances;

        PriceRatioState memory _priceRatioState = priceRatioState;

        uint256 currentFourthRootPriceRatio = calculateFourthRootPriceRatio(
            currentTimestamp,
            _priceRatioState.startFourthRootPriceRatio,
            _priceRatioState.endFourthRootPriceRatio,
            _priceRatioState.priceRatioUpdateStartTime,
            _priceRatioState.priceRatioUpdateEndTime
        );

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

        // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
        // Skip the update if the start and end price ratio are the same, because the virtual balances are already
        // calculated.
        if (
            currentTimestamp > _priceRatioState.priceRatioUpdateStartTime &&
            lastTimestamp < _priceRatioState.priceRatioUpdateEndTime &&
            _priceRatioState.startFourthRootPriceRatio != _priceRatioState.endFourthRootPriceRatio
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
            currentVirtualBalances = calculateVirtualBalancesUpdatingPriceRange(
                currentFourthRootPriceRatio,
                balancesScaled18,
                currentVirtualBalances,
                isPoolAboveCenter,
                priceShiftDailyRangeInSeconds,
                currentTimestamp,
                lastTimestamp
            );

            changed = true;
        }
    }

    /**
     * @notice Calculate the virtual balances of the pool when the price ratio is updating.
     * @dev This function uses a Bhaskara formula to shrink/expand the price interval by recalculating the virtual
     * balances. It'll keep the pool centeredness constant, and track the desired price ratio. To derive this formula,
     * we need to solve the following simultaneous equations:
     *
     * 1. centeredness = (Ra * Vb) / (Rb * Va)
     * 2. PriceRatio = invariant^2/(Va * Vb)^2 (maxPrice / minPrice)
     * 3. invariant = (Va + Ra) * (Vb + Rb)
     *
     * Substitute [3] in [2]. Then, isolate one of the V's. Finally, replace the isolated V in [1]. We get a quadratic
     * equation that will be solved in this function.
     *
     * @param currentFourthRootPriceRatio The current fourth root of the price ratio of the pool
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
        // The overvalued token is the one with a lower token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);
        uint256 balanceTokenUndervalued = balancesScaled18[indexTokenUndervalued];
        uint256 balanceTokenOvervalued = balancesScaled18[indexTokenOvervalued];

        virtualBalances = new uint256[](2);

        // Calculate the current pool centeredness, which will remain constant.
        uint256 poolCenteredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

        // The original formula was a quadratic equation, with terms:
        // a = Q0 - 1
        // b = - Ru (1 + C)
        // c = - Ru^2 C
        // where Q0 is the square root of the price ratio, Ru is the undervalued token balance, and C is the
        // centeredness. Applying Bhaskara, we'd have: Vu = (b + sqrt(b^2 - 4ac)) / 2a.
        // The Bhaskara above can be simplified buy replacing a, b and c with the terms above, which leads to:
        // Vu = Ru(1 + C + sqrt(1 + C (C + 4 Q0 - 2))) / 2(Q0 - 1)

        uint256 sqrtPriceRatio = currentFourthRootPriceRatio.mulUp(currentFourthRootPriceRatio);

        // Using FixedPoint math as little as possible to improve the precision of the result.
        uint256 virtualBalanceUndervalued = (balanceTokenUndervalued *
            (FixedPoint.ONE +
                poolCenteredness +
                Math.sqrt(poolCenteredness * (poolCenteredness + 4 * sqrtPriceRatio - 2e18) + 1e36))) /
            (2 * (sqrtPriceRatio - FixedPoint.ONE));
        virtualBalances[indexTokenOvervalued] = ((balanceTokenOvervalued * virtualBalanceUndervalued) /
            balanceTokenUndervalued).divDown(poolCenteredness);
        virtualBalances[indexTokenUndervalued] = virtualBalanceUndervalued;
    }

    /**
     * @notice Calculate the virtual balances when the pool is out of range, effectively adjusting the price range.
     * @dev This function will track the market price by moving the price interval. It will increase the pool
     * centeredness and change the token prices.
     *
     * @param currentFourthRootPriceRatio The current fourth root of price ratio of the pool
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param isPoolAboveCenter Whether the pool is above or below the center
     * @param priceShiftDailyRangeInSeconds IncreaseDayRate divided by 124649
     * @param currentTimestamp The current timestamp
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @return virtualBalances The new virtual balances of the pool
     */
    function calculateVirtualBalancesUpdatingPriceRange(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances,
        bool isPoolAboveCenter,
        uint256 priceShiftDailyRangeInSeconds,
        uint32 currentTimestamp,
        uint32 lastTimestamp
    ) internal pure returns (uint256[] memory) {
        // Round up price ratio, to round virtual balances down.
        uint256 priceRatio = currentFourthRootPriceRatio.mulUp(currentFourthRootPriceRatio);

        // The token overvalued is the one with low token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);

        // Vb = Vb * (1 - priceShiftDailyRangeInSeconds)^(Tcurr - Tlast)
        virtualBalances[indexTokenOvervalued] = virtualBalances[indexTokenOvervalued].mulDown(
            LogExpMath.pow(
                FixedPoint.ONE - priceShiftDailyRangeInSeconds,
                (currentTimestamp - lastTimestamp) * FixedPoint.ONE
            )
        );
        // Va = (Ra * (Vb + Rb)) / (((priceRatio - 1) * Vb) - Rb)
        virtualBalances[indexTokenUndervalued] =
            (balancesScaled18[indexTokenUndervalued] *
                (virtualBalances[indexTokenOvervalued] + balancesScaled18[indexTokenOvervalued])) /
            ((priceRatio - FixedPoint.ONE).mulDown(virtualBalances[indexTokenOvervalued]) -
                balancesScaled18[indexTokenOvervalued]);

        return virtualBalances;
    }

    /**
     * @notice Check whether the pool is in range.
     * @dev The pool is in range if the centeredness is greater than the centeredness margin.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalances The last virtual balances, sorted in token registration order
     * @param centerednessMargin A symmetrical measure of how closely an unbalanced pool can approach the limits of the
     * price range before it is considered out of range
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
     * balances. It's a percentage value, where 100% means that the token prices are centered, and 0% means that the
     * token prices are at the edge of the price interval.
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

        // Round up the centeredness, so the virtual balances are rounded down when the pool prices are moving.
        return
            ((balancesScaled18[indexTokenOvervalued] * virtualBalances[indexTokenUndervalued]) /
                balancesScaled18[indexTokenUndervalued]).divUp(virtualBalances[indexTokenOvervalued]);
    }

    /**
     * @notice Calculate the fourth root of the price ratio of the pool.
     * @dev The current fourth root of price ratio is an interpolation of the price ratio between the start and end
     * values in the price ratio state, using the percentage elapsed between the start and end times.
     *
     * @param currentTime The current timestamp
     * @param startFourthRootPriceRatio The start fourth root of price ratio of the pool
     * @param endFourthRootPriceRatio The end fourth root of price ratio of the pool
     * @param priceRatioUpdateStartTime The timestamp of the last user interaction with the pool
     * @param priceRatioUpdateEndTime The timestamp of the next user interaction with the pool
     * @return fourthRootPriceRatio The fourth root of price ratio of the pool
     */
    function calculateFourthRootPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 priceRatioUpdateStartTime,
        uint32 priceRatioUpdateEndTime
    ) internal pure returns (uint96) {
        if (currentTime <= priceRatioUpdateStartTime) {
            return startFourthRootPriceRatio;
        } else if (currentTime >= priceRatioUpdateEndTime) {
            return endFourthRootPriceRatio;
        } else if (startFourthRootPriceRatio == endFourthRootPriceRatio) {
            return endFourthRootPriceRatio;
        }

        uint256 exponent = uint256(currentTime - priceRatioUpdateStartTime).divDown(
            priceRatioUpdateEndTime - priceRatioUpdateStartTime
        );

        return
            ((uint256(startFourthRootPriceRatio) * LogExpMath.pow(endFourthRootPriceRatio, exponent)) /
                LogExpMath.pow(startFourthRootPriceRatio, exponent)).toUint96();
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
     * @notice Convert a raw daily rate into the time constant value used internally.
     * @param priceShiftDailyRate The price shift daily rate
     * @return priceShiftDailyRangeInSeconds The time constant
     */
    function computePriceShiftDailyRate(uint256 priceShiftDailyRate) internal pure returns (uint128) {
        // Divide daily rate by a number of seconds per day (plus some adjustment)
        return (priceShiftDailyRate / _SECONDS_PER_DAY_WITH_ADJUSTMENT).toUint128();
    }
}
