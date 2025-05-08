// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { LogExpMath } from "@balancer-labs/v3-solidity-utils/contracts/math/LogExpMath.sol";

struct VirtualBalances {
    uint256 virtualBalanceA;
    uint256 virtualBalanceB;
    uint256 errorVirtualBalanceA;
    uint256 errorVirtualBalanceB;
}

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

    /// @notice The swap result is greater than the real balance of the token (i.e., the balance would drop below zero).
    error AmountOutGreaterThanBalance();

    /// @notice The swap result is negative due to a rounding issue.
    error NegativeAmountOut();

    // When a pool is outside the target range, we start adjusting the price range by altering the virtual balances,
    // which affects the price. At a DailyPriceShiftExponent of 100%, we want to be able to change the price by a factor
    // of two: either doubling or halving it over the course of a day (86,400 seconds). The virtual balances must
    // change at the same rate. Therefore, if we want to double it in a day:
    //
    // 1. `V_next = 2*V_current`
    // 2. In the equation `V_next = V_current * (1 - tau)^(n+1)`, isolate tau.
    // 3. Replace `V_next` with `2*V_current` and `n` with `86400` to get `tau = 1 - pow(2, 1/(86400+1))`.
    // 4. Since `tau = dailyPriceShiftExponent/x`, then `x = dailyPriceShiftExponent/tau`.
    //    Since dailyPriceShiftExponent = 100%, then `x = 100%/(1 - pow(2, 1/(86400+1)))`, which is 124649.
    //
    // This constant shall be used to scale the dailyPriceShiftExponent, which is a percentage, to the actual value of
    // tau that will be used in the formula.
    uint256 private constant _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT = 124649;

    // We need to use a random number to calculate the initial virtual and real balances. This number will be scaled
    // later, during initialization, according to the actual liquidity added. Choosing a large number will maintain
    // precision when the pool is initialized with large amounts.
    uint256 private constant _INITIALIZATION_MAX_BALANCE_A = 1e6 * 1e18;

    /**
     * @notice Get the current virtual balances and compute the invariant of the pool using constant product.
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalanceA The last virtual balance of token A
     * @param lastVirtualBalanceB The last virtual balance of token B
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
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
        uint256 dailyPriceShiftBase,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage priceRatioState,
        Rounding rounding
    ) internal view returns (uint256 invariant) {
        VirtualBalances memory virtualBalances = computeCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalanceA,
            lastVirtualBalanceB,
            dailyPriceShiftBase,
            lastTimestamp,
            centerednessMargin,
            priceRatioState
        );

        return
            computeInvariant(
                balancesScaled18,
                virtualBalances.virtualBalanceA,
                virtualBalances.virtualBalanceB,
                rounding
            );
    }

    // TODO RECALCULATE WITH VIRTUAL BALANCES ERRORS
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
        uint256 errorVirtualBalanceA,
        uint256 errorVirtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountInScaled18
    ) internal pure returns (uint256 amountOutScaled18) {
        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA + errorVirtualBalanceA, virtualBalanceB)
            : (virtualBalanceB + errorVirtualBalanceB, virtualBalanceA);

        // amountOutScaled18 = currentTotalTokenOutPoolBalance - newTotalTokenOutPoolBalance,
        // where currentTotalTokenOutPoolBalance = balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut
        // and newTotalTokenOutPoolBalance = invariant / (currentTotalTokenInPoolBalance + amountInScaled18).a
        // Replace invariant with L = (x + a)(y + b), and simplify to arrive to:
        amountOutScaled18 =
            ((balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut) * amountInScaled18) /
            (balancesScaled18[tokenInIndex] + virtualBalanceTokenIn + amountInScaled18);
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
        uint256 errorVirtualBalanceA,
        uint256 errorVirtualBalanceB,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 amountOutScaled18
    ) internal pure returns (uint256 amountInScaled18) {
        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be greater than the real balance of the token in the pool.
            revert AmountOutGreaterThanBalance();
        }

        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA + errorVirtualBalanceA, virtualBalanceB)
            : (virtualBalanceB + errorVirtualBalanceB, virtualBalanceA);

        // amountInScaled18 = newTotalTokenOutPoolBalance - currentTotalTokenInPoolBalance,
        // where newTotalTokenOutPoolBalance = [invariant / (currentTotalTokenOutPoolBalance - amountOutScaled18)]
        // and currentTotalTokenInPoolBalance = balancesScaled18[tokenInIndex] + virtualBalanceTokenIn
        // Replace invariant with L = (x + a)(y + b), and simplify to arrive to:
        amountInScaled18 =
            ((balancesScaled18[tokenInIndex] + virtualBalanceTokenIn) * amountOutScaled18) /
            (balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut - amountOutScaled18);
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
     * @dev The update of the virtual balances follow these steps:
     *
     * 1. Calculate the current fourth root of price ratio.
     * 2. Shrink/Expand the price interval considering the current fourth root of price ratio.
     * 3. Track the market price by moving the price interval (if the pool is outside the target range).
     *
     * Note: Virtual balances will be rounded down so that the swap result favors the Vault.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param lastVirtualBalanceA The last virtual balance of token A
     * @param lastVirtualBalanceB The last virtual balance of token B
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
     * @param lastTimestamp The timestamp of the last user interaction with the pool
     * @param centerednessMargin A limit of the pool centeredness that defines if pool is outside the target range
     * @param storedPriceRatioState A struct containing start and end price ratios and a time interval
     * @return virtualBalances The current virtual balances of the pool
     */
    function computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        uint256 dailyPriceShiftBase,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage storedPriceRatioState
    ) internal view returns (VirtualBalances memory virtualBalances) {
        uint32 currentTimestamp = block.timestamp.toUint32();

        PriceRatioState memory priceRatioState = storedPriceRatioState;

        uint256 currentFourthRootPriceRatio = computeFourthRootPriceRatio(
            currentTimestamp,
            priceRatioState.startFourthRootPriceRatio,
            priceRatioState.endFourthRootPriceRatio,
            priceRatioState.priceRatioUpdateStartTime,
            priceRatioState.priceRatioUpdateEndTime
        );

        bool isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalanceA, lastVirtualBalanceB);

        virtualBalances = computeVirtualBalancesWithCurrentPriceRatio(
            currentFourthRootPriceRatio,
            balancesScaled18,
            lastVirtualBalanceA,
            lastVirtualBalanceB,
            isPoolAboveCenter
        );

        // If the pool is outside the target range, track the market price by moving the price interval.
        if (
            currentTimestamp > lastTimestamp &&
            isPoolWithinTargetRange(
                balancesScaled18,
                virtualBalances.virtualBalanceA,
                virtualBalances.virtualBalanceB,
                centerednessMargin
            ) ==
            false
        ) {
            // stack-too-deep
            uint256 _dailyPriceShiftBase = dailyPriceShiftBase;
            uint256[] memory _balancesScaled18 = balancesScaled18;
            uint32 _lastTimestamp = lastTimestamp;

            (
                virtualBalances.virtualBalanceA,
                virtualBalances.virtualBalanceB
            ) = computeVirtualBalancesUpdatingPriceRange(
                currentFourthRootPriceRatio,
                _balancesScaled18,
                virtualBalances.virtualBalanceA,
                virtualBalances.virtualBalanceB,
                isPoolAboveCenter,
                _dailyPriceShiftBase,
                currentTimestamp,
                _lastTimestamp
            );
        }
    }

    /**
     * @notice Compute the virtual balances of the pool with the current price ratio.
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
     * @return virtualBalances The current virtual balances of the pool
     */
    function computeVirtualBalancesWithCurrentPriceRatio(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB,
        bool isPoolAboveCenter
    ) internal pure returns (VirtualBalances memory virtualBalances) {
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

        uint256 virtualBalanceOvervalued = (balanceTokenOvervalued * virtualBalanceUndervalued).divDown(
            poolCenteredness * balanceTokenUndervalued
        );

        (uint256 errorVirtualBalanceUndervalued, uint256 errorVirtualBalanceOvervalued) = _computeErrorVirtualBalances(
            balanceTokenUndervalued,
            virtualBalanceUndervalued,
            balanceTokenOvervalued,
            virtualBalanceOvervalued,
            poolCenteredness,
            sqrtPriceRatio
        );

        virtualBalances = isPoolAboveCenter
            ? VirtualBalances({
                virtualBalanceA: virtualBalanceUndervalued,
                virtualBalanceB: virtualBalanceOvervalued,
                errorVirtualBalanceA: errorVirtualBalanceUndervalued,
                errorVirtualBalanceB: errorVirtualBalanceOvervalued
            })
            : VirtualBalances({
                virtualBalanceA: virtualBalanceOvervalued,
                virtualBalanceB: virtualBalanceUndervalued,
                errorVirtualBalanceA: errorVirtualBalanceOvervalued,
                errorVirtualBalanceB: errorVirtualBalanceUndervalued
            });
    }

    function _computeErrorVirtualBalances(
        uint256 balanceTokenUndervalued,
        uint256 virtualBalanceUndervalued,
        uint256 balanceTokenOvervalued,
        uint256 virtualBalanceOvervalued,
        uint256 poolCenteredness,
        uint256 sqrtPriceRatio
    ) internal pure returns (uint256 errorVirtualBalanceUndervalued, uint256 errorVirtualBalanceOvervalued) {
        uint256 virtualBalanceUndervaluedUp = ((balanceTokenUndervalued + 1) *
            (FixedPoint.ONE +
                poolCenteredness +
                1 +
                1 +
                Math.sqrt((poolCenteredness + 1) * (poolCenteredness + 1 + 4 * sqrtPriceRatio - 2e18) + 1e36))) /
            (2 * (sqrtPriceRatio - FixedPoint.ONE));

        uint256 virtualBalanceOvervaluedUp = ((balanceTokenOvervalued + 1) * virtualBalanceUndervaluedUp).divDown(
            poolCenteredness * balanceTokenUndervalued
        );

        return (
            virtualBalanceUndervaluedUp - virtualBalanceUndervalued,
            virtualBalanceOvervaluedUp - virtualBalanceOvervalued
        );
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
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
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
        uint256 dailyPriceShiftBase,
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

        // Vb = Vb * (1 - tau)^(T_curr - T_last)
        // Vb = Vb * (dailyPriceShiftBase)^(T_curr - T_last)
        virtualBalanceOvervalued = virtualBalanceOvervalued.mulDown(
            LogExpMath.pow(dailyPriceShiftBase, (currentTimestamp - lastTimestamp) * FixedPoint.ONE)
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

    /**
     * @notice Convert from the external to the internal representation of the daily price shift exponent.
     * @param dailyPriceShiftExponent The daily price shift exponent as an 18-decimal FP
     * @return dailyPriceShiftBase Internal representation of the daily price shift exponent
     */
    function toDailyPriceShiftBase(uint256 dailyPriceShiftExponent) internal pure returns (uint256) {
        return FixedPoint.ONE - dailyPriceShiftExponent / _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT;
    }

    /**
     * @notice Convert from the internal to the external representation of the daily price shift exponent.
     * @dev The result is an 18-decimal FP percentage.
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
     * @return dailyPriceShiftExponent The daily price shift exponent as an 18-decimal FP percentage
     */
    function toDailyPriceShiftExponent(uint256 dailyPriceShiftBase) internal pure returns (uint256) {
        return (FixedPoint.ONE - dailyPriceShiftBase) * _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT;
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
