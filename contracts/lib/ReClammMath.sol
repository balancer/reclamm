// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import "forge-std/console.sol";
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

// ReClamm pools are always 2-token pools, and the documentation assigns the first token (in sorted order) the
// subscript `a`, and the second token `b`. Define these here to make the code more readable and self-documenting.
uint256 constant a = 0;
uint256 constant b = 1;

library ReClammMath {
    using FixedPoint for uint256;
    using SafeCast for *;
    using ReClammMath for bool;

    /// @notice Determines whether the pool is above center or not, or if the computation has not taken place yet.
    enum PoolAboveCenter {
        FALSE,
        TRUE,
        UNKNOWN
    }

    /// @notice The swap result is greater than the real balance of the token (i.e., the balance would drop below zero).
    error AmountOutGreaterThanBalance();

    /// @notice The swap result is negative due to a rounding issue.
    error NegativeAmountOut();

    // When a pool is outside the target range, we start adjusting the price range by altering the virtual balances,
    // which affects the price. At a PriceShiftDailyRate of 100%, we want to be able to change the price by a factor
    // of two: either doubling or halving it over the course of a day (86,400 seconds). The virtual balances must
    // change at the same rate. Therefore, if we want to double it in a day:
    //
    // 1. `V_next = 2*V_current`
    // 2. In the equation `V_next = V_current * (1 - tau)^(n+1)`, isolate tau.
    // 3. Replace `V_next` with `2*V_current` and `n` with `86400` to get `tau = 1 - pow(2, 1/(86400+1))`.
    // 4. Since `tau = priceShiftDailyRate/x`, then `x = priceShiftDailyRate/tau`. Since priceShiftDailyRate = 100%,
    //    then `x = 100%/(1 - pow(2, 1/(86400+1)))`, which is 124649.
    uint256 private constant _SECONDS_PER_DAY_WITH_ADJUSTMENT = 124649;

    // We need to use a random number to calculate the initial virtual and real balances. This number will be scaled
    // later, during initialization, according to the actual liquidity added. Choosing a large number will maintain
    // precision when the pool is initialized with large amounts.
    uint256 private constant _INITIALIZATION_MAX_BALANCE_A = 1e6 * 1e18;

    /**
     * @notice Get the current virtual balances and compute the invariant of the pool using constant product.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalanceA The last virtual balance of token A
     * @param lastVirtualBalanceB The last virtual balance of token B
     * @param priceShiftDailyRateInSeconds IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param centerednessMargin A symmetrical measure of how closely an unbalanced pool can approach the limits of the
     * price range before it is considered outside the target range
     * @param priceRatioState A struct containing start and end price ratios and a time interval
     * @param rounding Rounding direction to consider when computing the invariant
     * @return invariant The invariant of the pool
     */
    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        uint256 priceShiftDailyRateInSeconds,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState,
        Rounding rounding
    ) internal view returns (uint256 invariant) {
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = computeCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalanceA,
            lastVirtualBalanceB,
            priceShiftDailyRateInSeconds,
            lastTimestamp,
            centerednessMargin,
            priceRatioState
        );

        return computeInvariant(balancesScaled18, virtualBalanceA, virtualBalanceB, rounding);
    }

    /**
     * @notice Compute the invariant of the pool using constant product.
     * @dev Note that the invariant is computed as (x+a)(y+b), without a square root. This is because the calculations
     * of virtual balance updates are easier with this invariant. Unlike most other pools, the ReClamm invariant will
     * change over time, if the pool is outside the target range, or the price ratio is updating, so these pools are
     * not composable. Therefore, the BPT value is meaningless.
     *
     * Consequently, liquidity can only be added or removed proportionally, as these operations do not depend on the
     * invariant. Therefore, it does not matter that the relationship between the invariant and liquidity is non-
     * linear; the invariant is only used to calculate swaps.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balance of token A
     * @param virtualBalanceB The last virtual balance of token B
     * @param rounding Rounding direction to consider when computing the invariant
     * @return invariant The invariant of the pool
     */
    function computeInvariant(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        Rounding rounding
    ) internal pure returns (uint256) {
        function(uint256, uint256) pure returns (uint256) _mulUpOrDown = rounding == Rounding.ROUND_DOWN
            ? FixedPoint.mulDown
            : FixedPoint.mulUp;

        return _mulUpOrDown((balancesScaled18[a] + virtualBalanceA), (balancesScaled18[b] + virtualBalanceB));
    }

    /**
     * @notice Compute the `amountOut` of tokenOut in a swap, given the current balances and virtual balances.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceAе The last virtual balance of token A
     * @param virtualBalanceB The last virtual balance of token B
     * @param tokenInIndex Index of the token being swapped in
     * @param tokenOutIndex Index of the token being swapped out
     * @param amountInScaled18 The exact amount of `tokenIn` (i.e., the amount given in an ExactIn swap)
     * @return amountOutScaled18 The calculated amount of `tokenOut` returned in an ExactIn swap
     */
    function computeOutGivenIn(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountInScaled18
    ) internal pure returns (uint256 amountOutScaled18) {
        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);

        // Round up, so the swapper absorbs rounding imprecisions (rounds in favor of the Vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalanceA, virtualBalanceB, Rounding.ROUND_UP);
        // Total (virtual + real) token out amount that should stay in the pool after the swap. Rounding division up,
        // which will round the token out amount down, favoring the Vault.
        uint256 newTotalTokenOutPoolBalance = invariant.divUp(
            balancesScaled18[tokenInIndex] + virtualBalanceTokenIn + amountInScaled18
        );

        uint256 currentTotalTokenOutPoolBalance = balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut;

        if (newTotalTokenOutPoolBalance > currentTotalTokenOutPoolBalance) {
            // If the amount of `tokenOut` remaining in the pool post-swap is greater than the total balance of
            // `tokenOut`, that means the swap result is negative due to a rounding issue.
            revert NegativeAmountOut();
        }

        amountOutScaled18 = currentTotalTokenOutPoolBalance - newTotalTokenOutPoolBalance;

        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be greater than the real balance of the token.
            revert AmountOutGreaterThanBalance();
        }
    }

    /**
     * @notice Compute the `amountIn` of tokenIn in a swap, given the current balances and virtual balances.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balances of token A
     * @param virtualBalanceB The last virtual balances of token B
     * @param tokenInIndex Index of the token being swapped in
     * @param tokenOutIndex Index of the token being swapped out
     * @param amountOutScaled18 The exact amount of `tokenOut` (i.e., the amount given in an ExactOut swap)
     * @return amountInScaled18 The calculated amount of `tokenIn` returned in an ExactOut swap
     */
    function computeInGivenOut(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountOutScaled18
    ) internal pure returns (uint256 amountInScaled18) {
        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be greater than the real balance of the token in the pool.
            revert AmountOutGreaterThanBalance();
        }

        // Round up, so the swapper absorbs any imprecision due to rounding (i.e., it rounds in favor of the Vault).
        uint256 invariant = computeInvariant(balancesScaled18, virtualBalanceA, virtualBalanceB, Rounding.ROUND_UP);

        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);

        // Rounding division up, which will round the `tokenIn` amount up, favoring the Vault.
        amountInScaled18 =
            invariant.divUp(balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut - amountOutScaled18) -
            balancesScaled18[tokenInIndex] -
            virtualBalanceTokenIn;
    }

    /**
     * @notice Computes the theoretical initial state of a ReClamm pool based on its price parameters.
     * @dev This function calculates three key components needed to initialize a ReClamm pool:
     * 1. Initial real token balances - Using a reference value (_INITIALIZATION_MAX_BALANCE_A) that will be
     *    scaled later during actual pool initialization based on the actual tokens provided
     * 2. Initial virtual balances - Additional balances used to control the pool's price range
     * 3. Fourth root price ratio - A key parameter that helps define the pool's price boundaries
     *
     * Note: The actual balances used in pool initialization will be proportionally scaled versions
     * of these theoretical values, maintaining the same ratios but adjusted to the actual amount of
     * liquidity provided.
     *
     * Price is defined as (balanceB + virtualBalanceB) / (balanceA + virtualBalanceA),
     * where A and B are the pool tokens, sorted by address (A is the token with the lowest address).
     * For example, if the pool is ETH/USDC, and USDC has an address that is smaller than ETH, this price will
     * be defined as ETH/USDC (meaning, how much ETH is required to buy 1 USDC).
     *
     * @param minPrice The minimum price limit of the pool
     * @param maxPrice The maximum price limit of the pool
     * @param targetPrice The desired initial price point within the total price range (i.e., the midpoint)
     * @return realBalances Array of theoretical initial token balances [tokenA, tokenB]
     * @return virtualBalanceA The theoretical initial virtual balance of token A [virtualA]
     * @return virtualBalanceB The theoretical initial virtual balance of token B [virtualB]
     * @return fourthRootPriceRatio The fourth root of maxPrice/minPrice ratio
     */
    function computeTheoreticalPriceRatioAndBalances(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice
    )
        internal
        pure
        returns (
            uint256[] memory realBalances,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 fourthRootPriceRatio
        )
    {
        // In the formulas below, Ra_max is a random number that defines the maximum real balance of token A, and
        // consequently a random initial liquidity. We will scale all balances according to the actual amount of
        // liquidity provided during initialization.
        uint256 sqrtPriceRatio = sqrtScaled18(maxPrice.divDown(minPrice));
        fourthRootPriceRatio = sqrtScaled18(sqrtPriceRatio);

        // Va = Ra_max / (sqrtPriceRatio - 1)
        virtualBalanceA = _INITIALIZATION_MAX_BALANCE_A.divDown(sqrtPriceRatio - FixedPoint.ONE);
        // Vb = minPrice * (Va + Ra_max)
        virtualBalanceB = minPrice.mulDown(virtualBalanceA + _INITIALIZATION_MAX_BALANCE_A);

        realBalances = new uint256[](2);
        // Rb = sqrt(targetPrice * Vb * (Ra_max + Va)) - Vb
        realBalances[b] =
            sqrtScaled18(targetPrice.mulUp(virtualBalanceB).mulUp(_INITIALIZATION_MAX_BALANCE_A + virtualBalanceA)) -
            virtualBalanceB;
        // Ra = (Rb + Vb - (Va * targetPrice)) / targetPrice
        realBalances[a] = (realBalances[b] + virtualBalanceB - virtualBalanceA.mulDown(targetPrice)).divDown(
            targetPrice
        );
    }

    /**
     * @notice Calculate the current virtual balances of the pool.
     * @dev If the pool is within the target range, or the price ratio is not updating, the virtual balances do not
     * change, and we return lastVirtualBalances. Otherwise, follow these three steps:
     *
     * 1. Calculate the current fourth root of price ratio.
     * 2. Shrink/Expand the price interval considering the current fourth root of price ratio (if the price ratio
     *    is updating).
     * 3. Track the market price by moving the price interval (if the pool is outside the target range).
     *
     * Note: Virtual balances will be rounded down so that the swap result favors the Vault.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalanceA The last virtual balance of token A
     * @param lastVirtualBalanceB The last virtual balance of token B
     * @param priceShiftDailyRateInSeconds IncreaseDayRate divided by 124649
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is outside the target range
     * @param storedPriceRatioState A struct containing start and end price ratios and a time interval
     * @return currentVirtualBalanceA The current virtual balance of token A
     * @return currentVirtualBalanceB The current virtual balance of token B
     * @return changed Whether the virtual balances have changed and must be updated in the pool
     */
    function computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        uint256 priceShiftDailyRateInSeconds,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage storedPriceRatioState
    ) internal view returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) {
        uint32 currentTimestamp = block.timestamp.toUint32();

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == currentTimestamp) {
            return (lastVirtualBalanceA, lastVirtualBalanceB, false);
        }

        currentVirtualBalanceA = lastVirtualBalanceA;
        currentVirtualBalanceB = lastVirtualBalanceB;

        PriceRatioState memory priceRatioState = storedPriceRatioState;

        uint256 currentFourthRootPriceRatio = computeFourthRootPriceRatio(
            currentTimestamp,
            priceRatioState.startFourthRootPriceRatio,
            priceRatioState.endFourthRootPriceRatio,
            priceRatioState.priceRatioUpdateStartTime,
            priceRatioState.priceRatioUpdateEndTime
        );

        // Postponing the calculation of isPoolAboveCenter saves gas when the pool is within the target range and the
        // price ratio is not updating.
        PoolAboveCenter isPoolAboveCenter = PoolAboveCenter.UNKNOWN;

        // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
        // Skip the update if the start and end price ratio are the same, because the virtual balances are already
        // calculated.
        if (
            currentTimestamp > priceRatioState.priceRatioUpdateStartTime &&
            lastTimestamp < priceRatioState.priceRatioUpdateEndTime
        ) {
            isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalanceA, lastVirtualBalanceB).toEnum();

            (currentVirtualBalanceA, currentVirtualBalanceB) = computeVirtualBalancesUpdatingPriceRatio(
                currentFourthRootPriceRatio,
                balancesScaled18,
                lastVirtualBalanceA,
                lastVirtualBalanceB,
                isPoolAboveCenter == PoolAboveCenter.TRUE
            );

            changed = true;
        }

        // If the pool is outside the target range, track the market price by moving the price interval.
        if (
            isPoolWithinTargetRange(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                centerednessMargin
            ) == false
        ) {
            if (isPoolAboveCenter == PoolAboveCenter.UNKNOWN) {
                isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalanceA, lastVirtualBalanceB).toEnum();
            }

            // stack-too-deep
            uint256 _priceShiftDailyRateInSeconds = priceShiftDailyRateInSeconds;
            uint256[] memory _balancesScaled18 = balancesScaled18;
            uint32 _lastTimestamp = lastTimestamp;

            (currentVirtualBalanceA, currentVirtualBalanceB) = computeVirtualBalancesUpdatingPriceRange(
                currentFourthRootPriceRatio,
                _balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                isPoolAboveCenter == PoolAboveCenter.TRUE,
                _priceShiftDailyRateInSeconds,
                currentTimestamp,
                _lastTimestamp
            );

            changed = true;
        }
    }

    /**
     * @notice Compute the virtual balances of the pool when the price ratio is updating.
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
     * @param lastVirtualBalanceA The last virtual balance of token A
     * @param lastVirtualBalanceB The last virtual balance of token B
     * @param isPoolAboveCenter Whether the pool is above or below the center
     * @return virtualBalanceA The virtual balance of token A
     * @return virtualBalanceB The virtual balance of token B
     */
    function computeVirtualBalancesUpdatingPriceRatio(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        bool isPoolAboveCenter
    ) internal pure returns (uint256 virtualBalanceA, uint256 virtualBalanceB) {
        // The overvalued token is the one with a lower token balance (therefore, rarer and more valuable).
        (uint256 indexTokenUndervalued, uint256 indexTokenOvervalued) = isPoolAboveCenter ? (0, 1) : (1, 0);
        uint256 balanceTokenUndervalued = balancesScaled18[indexTokenUndervalued];
        uint256 balanceTokenOvervalued = balancesScaled18[indexTokenOvervalued];

        // Compute the current pool centeredness, which will remain constant.
        uint256 poolCenteredness = computeCenteredness(balancesScaled18, lastVirtualBalanceA, lastVirtualBalanceB);

        // The original formula was a quadratic equation, with terms:
        // a = Q0 - 1
        // b = - Ru (1 + C)
        // c = - Ru^2 C
        // where Q0 is the square root of the price ratio, Ru is the undervalued token balance, and C is the
        // centeredness. Applying Bhaskara, we'd have: Vu = (-b + sqrt(b^2 - 4ac)) / 2a.
        // The Bhaskara above can be simplified by replacing a, b and c with the terms above, which leads to:
        // Vu = Ru(1 + C + sqrt(1 + C (C + 4 Q0 - 2))) / 2(Q0 - 1)
        uint256 sqrtPriceRatio = currentFourthRootPriceRatio.mulUp(currentFourthRootPriceRatio);

        // Using FixedPoint math as little as possible to improve the precision of the result.
        // Note: The input of Math.sqrt must be a 36-decimal number, so that the final result is 18 decimals.
        uint256 virtualBalanceUndervalued = (balanceTokenUndervalued *
            (FixedPoint.ONE +
                poolCenteredness +
                Math.sqrt(poolCenteredness * (poolCenteredness + 4 * sqrtPriceRatio - 2e18) + 1e36))) /
            (2 * (sqrtPriceRatio - FixedPoint.ONE));

        uint256 virtualBalanceOvervalued = ((balanceTokenOvervalued * virtualBalanceUndervalued) /
            balanceTokenUndervalued).divDown(poolCenteredness);

        (virtualBalanceA, virtualBalanceB) = isPoolAboveCenter
            ? (virtualBalanceUndervalued, virtualBalanceOvervalued)
            : (virtualBalanceOvervalued, virtualBalanceUndervalued);
    }

    /**
     * @notice Compute new virtual balances when the pool is outside the target range.
     * @dev This function will track the market price by moving the price interval. Note that it will increase the
     * pool centeredness and change the token prices.
     *
     * @param currentFourthRootPriceRatio The current fourth root of price ratio of the pool
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balance of token A
     * @param virtualBalanceB The last virtual balance of token B
     * @param isPoolAboveCenter Whether the pool is above or below the center of the price range
     * @param priceShiftDailyRateInSeconds IncreaseDayRate divided by 124649
     * @param currentTimestamp The current timestamp
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @return newVirtualBalanceA The new virtual balance of token A
     * @return newVirtualBalanceB The new virtual balance of token B
     */
    function computeVirtualBalancesUpdatingPriceRange(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        bool isPoolAboveCenter,
        uint256 priceShiftDailyRateInSeconds,
        uint32 currentTimestamp,
        uint32 lastTimestamp
    ) internal pure returns (uint256 newVirtualBalanceA, uint256 newVirtualBalanceB) {
        // Round up price ratio, to round virtual balances down.
        uint256 priceRatio = currentFourthRootPriceRatio.mulUp(currentFourthRootPriceRatio);

        // The overvalued token is the one with a lower token balance (therefore, rarer and more valuable).
        (uint256 balancesScaledUndervalued, uint256 balancesScaledOvervalued) = isPoolAboveCenter
            ? (balancesScaled18[a], balancesScaled18[b])
            : (balancesScaled18[b], balancesScaled18[a]);
        (uint256 virtualBalanceUndervalued, uint256 virtualBalanceOvervalued) = isPoolAboveCenter
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);

        // Vb = Vb * (1 - priceShiftDailyRateInSeconds)^(T_curr - T_last)
        virtualBalanceOvervalued = virtualBalanceOvervalued.mulDown(
            LogExpMath.pow(
                FixedPoint.ONE - priceShiftDailyRateInSeconds,
                (currentTimestamp - lastTimestamp) * FixedPoint.ONE
            )
        );
        // Va = (Ra * (Vb + Rb)) / (((priceRatio - 1) * Vb) - Rb)
        virtualBalanceUndervalued =
            (balancesScaledUndervalued * (virtualBalanceOvervalued + balancesScaledOvervalued)) /
            ((priceRatio - FixedPoint.ONE).mulDown(virtualBalanceOvervalued) - balancesScaledOvervalued);

        (newVirtualBalanceA, newVirtualBalanceB) = isPoolAboveCenter
            ? (virtualBalanceUndervalued, virtualBalanceOvervalued)
            : (virtualBalanceOvervalued, virtualBalanceUndervalued);
    }

    /**
     * @notice Check whether the pool is in range.
     * @dev The pool is in range if the centeredness is greater than the centeredness margin.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balances of token A
     * @param virtualBalanceB The last virtual balances of token B
     * @param centerednessMargin A symmetrical measure of how closely an unbalanced pool can approach the limits of the
     * price range before it is considered out of range
     * @return isWithinTargetRange Whether the pool is within the target price range
     */
    function isPoolWithinTargetRange(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 centerednessMargin
    ) internal pure returns (bool) {
        uint256 centeredness = computeCenteredness(balancesScaled18, virtualBalanceA, virtualBalanceB);
        return centeredness >= centerednessMargin;
    }

    /**
     * @notice Compute the centeredness of the pool.
     * @dev The centeredness is calculated as the ratio of the real balances divided by the ratio of the virtual
     * balances. It's a percentage value, where 100% means that the token prices are centered, and 0% means that the
     * token prices are at the edge of the price interval.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balances of token A
     * @param virtualBalanceB The last virtual balances of token B
     * @return poolCenteredness The centeredness of the pool
     */
    function computeCenteredness(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure returns (uint256) {
        if (balancesScaled18[a] == 0 || balancesScaled18[b] == 0) {
            return 0;
        }

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, virtualBalanceA, virtualBalanceB);

        // The overvalued token is the one with a lower token balance (therefore, rarer and more valuable).
        (uint256 virtualBalanceUndervalued, uint256 virtualBalanceOvervalued) = isPoolAboveCenter
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);
        (uint256 balancesScaledUndervalued, uint256 balancesScaledOvervalued) = isPoolAboveCenter
            ? (balancesScaled18[a], balancesScaled18[b])
            : (balancesScaled18[b], balancesScaled18[a]);

        // Round up the centeredness, so the virtual balances are rounded down when the pool prices are moving.
        return
            ((balancesScaledOvervalued * virtualBalanceUndervalued) / balancesScaledUndervalued).divUp(
                virtualBalanceOvervalued
            );
    }

    /**
     * @notice Compute the fourth root of the price ratio of the pool.
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
    function computeFourthRootPriceRatio(
        uint32 currentTime,
        uint96 startFourthRootPriceRatio,
        uint96 endFourthRootPriceRatio,
        uint32 priceRatioUpdateStartTime,
        uint32 priceRatioUpdateEndTime
    ) internal pure returns (uint96) {
        // if start and end time are the same, return end value.
        if (currentTime >= priceRatioUpdateEndTime) {
            return endFourthRootPriceRatio;
        } else if (currentTime <= priceRatioUpdateStartTime) {
            return startFourthRootPriceRatio;
        }

        uint256 exponent = uint256(currentTime - priceRatioUpdateStartTime).divDown(
            priceRatioUpdateEndTime - priceRatioUpdateStartTime
        );

        return
            ((uint256(startFourthRootPriceRatio) * LogExpMath.pow(endFourthRootPriceRatio, exponent)) /
                LogExpMath.pow(startFourthRootPriceRatio, exponent)).toUint96();
    }

    /**
     * @notice Check whether the pool is above center.
     * @dev The pool is above center if the ratio of the real balances is greater than the ratio of the virtual
     * balances.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA The last virtual balance of token A
     * @param virtualBalanceB The last virtual balance of token B
     * @return isAboveCenter Whether the pool is above center
     */
    function isAboveCenter(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure returns (bool) {
        if (balancesScaled18[b] == 0) {
            return true;
        } else {
            return balancesScaled18[a].divDown(balancesScaled18[b]) > virtualBalanceA.divDown(virtualBalanceB);
        }
    }

    /// @notice Convert a boolean value to a PoolAboveCenter enum (only TRUE or FALSE).
    function toEnum(bool value) internal pure returns (PoolAboveCenter) {
        return PoolAboveCenter(value.toUint());
    }

    /**
     * @notice Convert a raw daily rate into the value used internally.
     * @param priceShiftDailyRate The price shift daily rate
     * @return priceShiftDailyRateInSeconds Represents how fast the pool can move the virtual balances per day
     */
    function computePriceShiftDailyRate(uint256 priceShiftDailyRate) internal pure returns (uint128) {
        // Divide daily rate by a number of seconds per day (plus some adjustment)
        return (priceShiftDailyRate / _SECONDS_PER_DAY_WITH_ADJUSTMENT).toUint128();
    }

    /**
     * @notice Calculate the square root of a value scaled by 18 decimals.
     * @param valueScaled18 The value to calculate the square root of, scaled by 18 decimals
     * @return sqrtValueScaled18 The square root of the value scaled by 18 decimals
     */
    function sqrtScaled18(uint256 valueScaled18) internal pure returns (uint256) {
        return Math.sqrt(valueScaled18 * FixedPoint.ONE);
    }
}
