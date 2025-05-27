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
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = computeCurrentVirtualBalances(
            balancesScaled18,
            lastVirtualBalanceA,
            lastVirtualBalanceB,
            dailyPriceShiftBase,
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
        // `amountOutScaled18 = currentTotalTokenOutPoolBalance - newTotalTokenOutPoolBalance`,
        // where `currentTotalTokenOutPoolBalance = balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut`
        // and `newTotalTokenOutPoolBalance = invariant / (currentTotalTokenInPoolBalance + amountInScaled18)`.
        // In other words,
        // +--------------------------------------------------+
        // |                         L                        |
        // | Ao = Bo + Vo - ---------------------             |
        // |                   (Bi + Vi + Ai)                 |
        // +--------------------------------------------------+
        // Simplify by:
        // - replacing `L = (Bo + Vo) (Bi + Vi)`, and
        // - multiplying `(Bo + Vo)` by `(Bi + Vi + Ai) / (Bi + Vi + Ai)`:
        // +--------------------------------------------------+
        // |              (Bo + Vo) Ai                        |
        // | Ao = ------------------------------              |
        // |             (Bi + Vi + Ai)                       |
        // +--------------------------------------------------+
        // | Where:                                           |
        // |   Ao = Amount out                                |
        // |   Bo = Balance token out                         |
        // |   Vo = Virtual balance token out                 |
        // |   Ai = Amount in                                 |
        // |   Bi = Balance token in                          |
        // |   Vi = Virtual balance token in                  |
        // +--------------------------------------------------+
        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);

        amountOutScaled18 =
            ((balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut) * amountInScaled18) /
            (balancesScaled18[tokenInIndex] + virtualBalanceTokenIn + amountInScaled18);

        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be greater than the real balance of the token in the pool.
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
        // `amountInScaled18 = newTotalTokenOutPoolBalance - currentTotalTokenInPoolBalance`,
        // where `newTotalTokenOutPoolBalance = invariant / (currentTotalTokenOutPoolBalance - amountOutScaled18)`
        // and `currentTotalTokenInPoolBalance = balancesScaled18[tokenInIndex] + virtualBalanceTokenIn`.
        // In other words,
        // +--------------------------------------------------+
        // |               L                                  |
        // | Ai = --------------------- - (Bi + Vi)           |
        // |         (Bo + Vo - Ao)                           |
        // +--------------------------------------------------+
        // Simplify by:
        // - replacing `L = (Bo + Vo) (Bi + Vi)`, and
        // - multiplying `(Bi + Vi)` by `(Bo + Vo - Ao) / (Bo + Vo - Ao)`:
        // +--------------------------------------------------+
        // |              (Bi + Vi) Ao                        |
        // | Ai = ------------------------------              |
        // |             (Bo + Vo - Ao)                       |
        // +--------------------------------------------------+
        // | Where:                                           |
        // |   Ao = Amount out                                |
        // |   Bo = Balance token out                         |
        // |   Vo = Virtual balance token out                 |
        // |   Ai = Amount in                                 |
        // |   Bi = Balance token in                          |
        // |   Vi = Virtual balance token in                  |
        // +--------------------------------------------------+

        if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) {
            // Amount out cannot be greater than the real balance of the token in the pool.
            revert AmountOutGreaterThanBalance();
        }

        (uint256 virtualBalanceTokenIn, uint256 virtualBalanceTokenOut) = tokenInIndex == a
            ? (virtualBalanceA, virtualBalanceB)
            : (virtualBalanceB, virtualBalanceA);

        // Round up to favor the vault (i.e. request larger amount in from the user).
        amountInScaled18 = FixedPoint.mulDivUp(
            balancesScaled18[tokenInIndex] + virtualBalanceTokenIn,
            amountOutScaled18,
            balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut - amountOutScaled18
        );
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
     * @param minPriceScaled18 The minimum price limit of the pool
     * @param maxPriceScaled18 The maximum price limit of the pool
     * @param targetPriceScaled18 The desired initial price point within the total price range (i.e., the midpoint)
     * @return realBalancesScaled18 Array of theoretical initial token balances [tokenA, tokenB]
     * @return virtualBalanceAScaled18 The theoretical initial virtual balance of token A [virtualA]
     * @return virtualBalanceBScaled18 The theoretical initial virtual balance of token B [virtualB]
     * @return fourthRootPriceRatio The fourth root of maxPrice/minPrice ratio
     */
    function computeTheoreticalPriceRatioAndBalances(
        uint256 minPriceScaled18,
        uint256 maxPriceScaled18,
        uint256 targetPriceScaled18
    )
        internal
        pure
        returns (
            uint256[] memory realBalancesScaled18,
            uint256 virtualBalanceAScaled18,
            uint256 virtualBalanceBScaled18,
            uint256 fourthRootPriceRatio
        )
    {
        // In the formulas below, Ra_max is a random number that defines the maximum real balance of token A, and
        // consequently a random initial liquidity. We will scale all balances according to the actual amount of
        // liquidity provided during initialization.
        uint256 sqrtPriceRatio = sqrtScaled18(maxPriceScaled18.divDown(minPriceScaled18));
        fourthRootPriceRatio = sqrtScaled18(sqrtPriceRatio);

        // Va = Ra_max / (sqrtPriceRatio - 1)
        virtualBalanceAScaled18 = _INITIALIZATION_MAX_BALANCE_A.divDown(sqrtPriceRatio - FixedPoint.ONE);
        // Vb = minPrice * (Va + Ra_max)
        virtualBalanceBScaled18 = minPriceScaled18.mulDown(virtualBalanceAScaled18 + _INITIALIZATION_MAX_BALANCE_A);

        realBalancesScaled18 = new uint256[](2);
        // Rb = sqrt(targetPrice * Vb * (Ra_max + Va)) - Vb
        realBalancesScaled18[b] =
            sqrtScaled18(
                targetPriceScaled18.mulUp(virtualBalanceBScaled18).mulUp(
                    _INITIALIZATION_MAX_BALANCE_A + virtualBalanceAScaled18
                )
            ) -
            virtualBalanceBScaled18;
        // Ra = (Rb + Vb - (Va * targetPrice)) / targetPrice
        realBalancesScaled18[a] = (realBalancesScaled18[b] +
            virtualBalanceBScaled18 -
            virtualBalanceAScaled18.mulDown(targetPriceScaled18)).divDown(targetPriceScaled18);
    }

    struct VirtualBalancesLocals {
        uint32 currentTimestamp;
        uint256 currentFourthRootPriceRatio;
        uint256 centeredness;
        bool isPoolAboveCenter;
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
     * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
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
        uint256 dailyPriceShiftBase,
        uint32 lastTimestamp,
        uint64 centerednessMargin,
        PriceRatioState storage storedPriceRatioState
    ) internal view returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) {
        VirtualBalancesLocals memory locals;
        locals.currentTimestamp = block.timestamp.toUint32();

        // If the last timestamp is the same as the current timestamp, virtual balances were already reviewed in the
        // current block.
        if (lastTimestamp == locals.currentTimestamp) {
            return (lastVirtualBalanceA, lastVirtualBalanceB, false);
        }

        currentVirtualBalanceA = lastVirtualBalanceA;
        currentVirtualBalanceB = lastVirtualBalanceB;

        PriceRatioState memory priceRatioState = storedPriceRatioState;

        locals.currentFourthRootPriceRatio = computeFourthRootPriceRatio(
            locals.currentTimestamp,
            priceRatioState.startFourthRootPriceRatio,
            priceRatioState.endFourthRootPriceRatio,
            priceRatioState.priceRatioUpdateStartTime,
            priceRatioState.priceRatioUpdateEndTime
        );

        // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
        // Skip the update if the start and end price ratio are the same, because the virtual balances are already
        // calculated.
        if (
            locals.currentTimestamp > priceRatioState.priceRatioUpdateStartTime &&
            lastTimestamp < priceRatioState.priceRatioUpdateEndTime
        ) {
            (currentVirtualBalanceA, currentVirtualBalanceB) = computeVirtualBalancesUpdatingPriceRatio(
                locals.currentFourthRootPriceRatio,
                balancesScaled18,
                lastVirtualBalanceA,
                lastVirtualBalanceB
            );

            changed = true;
        }

        (locals.centeredness, locals.isPoolAboveCenter) = computeCenteredness(
            balancesScaled18,
            currentVirtualBalanceA,
            currentVirtualBalanceB
        );

        // If the pool is outside the target range, track the market price by moving the price interval.
        if (locals.centeredness < centerednessMargin) {
            (currentVirtualBalanceA, currentVirtualBalanceB) = computeVirtualBalancesUpdatingPriceRange(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                locals.isPoolAboveCenter,
                dailyPriceShiftBase,
                locals.currentTimestamp,
                lastTimestamp
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
     * @return virtualBalanceA The virtual balance of token A
     * @return virtualBalanceB The virtual balance of token B
     */
    function computeVirtualBalancesUpdatingPriceRatio(
        uint256 currentFourthRootPriceRatio,
        uint256[] memory balancesScaled18,
        uint256 lastVirtualBalanceA,
        uint256 lastVirtualBalanceB
    ) internal pure returns (uint256 virtualBalanceA, uint256 virtualBalanceB) {
        // Compute the current pool centeredness, which will remain constant.
        (uint256 poolCenteredness, bool isPoolAboveCenter) = computeCenteredness(
            balancesScaled18,
            lastVirtualBalanceA,
            lastVirtualBalanceB
        );

        // The overvalued token is the one with a lower token balance (therefore, rarer and more valuable).
        (
            uint256 balanceTokenUndervalued,
            uint256 lastVirtualBalanceUndervalued,
            uint256 lastVirtualBalanceOvervalued
        ) = isPoolAboveCenter
                ? (balancesScaled18[a], lastVirtualBalanceA, lastVirtualBalanceB)
                : (balancesScaled18[b], lastVirtualBalanceB, lastVirtualBalanceA);

        // The original formula was a quadratic equation, with terms:
        // a = Q0 - 1
        // b = - Ru (1 + C)
        // c = - Ru^2 C
        // where Q0 is the square root of the price ratio, Ru is the undervalued token balance, and C is the
        // centeredness. Applying Bhaskara, we'd have: Vu = (-b + sqrt(b^2 - 4ac)) / 2a.
        // The Bhaskara above can be simplified by replacing a, b and c with the terms above, which leads to:
        // Vu = Ru(1 + C + sqrt(1 + C (C + 4 Q0 - 2))) / 2(Q0 - 1)
        uint256 sqrtPriceRatio = currentFourthRootPriceRatio.mulDown(currentFourthRootPriceRatio);

        // Using FixedPoint math as little as possible to improve the precision of the result.
        // Note: The input of Math.sqrt must be a 36-decimal number, so that the final result is 18 decimals.
        uint256 virtualBalanceUndervalued = (balanceTokenUndervalued *
            (FixedPoint.ONE +
                poolCenteredness +
                Math.sqrt(poolCenteredness * (poolCenteredness + 4 * sqrtPriceRatio - 2e18) + 1e36))) /
            (2 * (sqrtPriceRatio - FixedPoint.ONE));

        uint256 virtualBalanceOvervalued = (virtualBalanceUndervalued * lastVirtualBalanceOvervalued) /
            lastVirtualBalanceUndervalued;

        (virtualBalanceA, virtualBalanceB) = isPoolAboveCenter
            ? (virtualBalanceUndervalued, virtualBalanceOvervalued)
            : (virtualBalanceOvervalued, virtualBalanceUndervalued);
    }

    /**
     * @notice Compute new virtual balances when the pool is outside the target range.
     * @dev This function will track the market price by moving the price interval. Note that it will increase the
     * pool centeredness and change the token prices.
     *
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
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        bool isPoolAboveCenter,
        uint256 dailyPriceShiftBase,
        uint32 currentTimestamp,
        uint32 lastTimestamp
    ) internal pure returns (uint256 newVirtualBalanceA, uint256 newVirtualBalanceB) {
        uint256 sqrtPriceRatio = Math.sqrt(
            computePriceRatio(balancesScaled18, virtualBalanceA, virtualBalanceB) * FixedPoint.ONE
        );

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
            ((sqrtPriceRatio - FixedPoint.ONE).mulDown(virtualBalanceOvervalued) - balancesScaledOvervalued);

        (newVirtualBalanceA, newVirtualBalanceB) = isPoolAboveCenter
            ? (virtualBalanceUndervalued, virtualBalanceOvervalued)
            : (virtualBalanceOvervalued, virtualBalanceUndervalued);
    }

    /**
     * @notice Check whether the pool is in range.
     * @dev The pool is in range if the centeredness is greater than or equal to the centeredness margin.
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
        (uint256 centeredness, ) = computeCenteredness(balancesScaled18, virtualBalanceA, virtualBalanceB);
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
     * @return isPoolAboveCenter True if the pool is above the center, false otherwise
     */
    function computeCenteredness(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure returns (uint256 poolCenteredness, bool isPoolAboveCenter) {
        if (balancesScaled18[a] == 0 || balancesScaled18[b] == 0) {
            return (0, true);
        }

        uint256 numerator = balancesScaled18[a] * virtualBalanceB;
        uint256 denominator = virtualBalanceA * balancesScaled18[b];

        // The centeredness is defined between 0 and 1. If the numerator is greater than the denominator, we compute
        // the inverse ratio.
        if (numerator <= denominator) {
            poolCenteredness = numerator.divDown(denominator);
            isPoolAboveCenter = false;
        } else {
            poolCenteredness = denominator.divDown(numerator);
            isPoolAboveCenter = true;
        }

        return (poolCenteredness, isPoolAboveCenter);
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
     * @notice Compute the price ratio of the pool by dividing the maximum price by the minimum price.
     * @dev The price ratio is calculated as maxPrice/minPrice, where maxPrice and minPrice are obtained
     * from computePriceRange.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA Virtual balance of token A
     * @param virtualBalanceB Virtual balance of token B
     * @return priceRatio The ratio between the maximum and minimum prices of the pool
     */
    function computePriceRatio(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure returns (uint256 priceRatio) {
        (uint256 minPrice, uint256 maxPrice) = computePriceRange(balancesScaled18, virtualBalanceA, virtualBalanceB);

        return maxPrice.divUp(minPrice);
    }

    /**
     * @notice Compute the minimum and maximum prices for the pool based on virtual balances and current invariant.
     * @dev The minimum price is calculated as Vb^2/invariant, where Vb is the virtual balance of token B.
     * The maximum price is calculated as invariant/Va^2, where Va is the virtual balance of token A.
     * These calculations are derived from the invariant equation: invariant = (Ra + Va)(Rb + Vb),
     * where Ra and Rb are the real balances of tokens A and B respectively.
     *
     * @param balancesScaled18 Current pool balances, sorted in token registration order
     * @param virtualBalanceA Virtual balance of token A
     * @param virtualBalanceB Virtual balance of token B
     * @return minPrice The minimum price of token A in terms of token B
     * @return maxPrice The maximum price of token A in terms of token B
     */
    function computePriceRange(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure returns (uint256 minPrice, uint256 maxPrice) {
        uint256 currentInvariant = ReClammMath.computeInvariant(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB,
            Rounding.ROUND_DOWN
        );

        // P_min(a) = Vb / (Va + Ra_max)
        // We don't have Ra_max, but: invariant=(Ra_max + Va)(Vb)
        // Then, (Va + Ra_max) = invariant/Vb, and:
        // P_min(a) = Vb^2 / invariant
        minPrice = (virtualBalanceB * virtualBalanceB) / currentInvariant;

        // Similarly, P_max(a) = (Rb_max + Vb)/Va
        // We don't have Rb_max, but: invariant=(Rb_max + Vb)(Va)
        // Then, (Rb_max + Vb) = invariant/Va, and:
        // P_max(a) = invariant / Va^2
        maxPrice = currentInvariant.divDown(virtualBalanceA.mulDown(virtualBalanceA));
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

    /**
     * @notice Raise a value to the fourth power (i.e., recover a range limit from its fourth root).
     * @dev Input and output are all 18-decimal floating point numbers.
     * @return limitValue `rootValue` raised to the fourth power
     */
    function pow4(uint256 rootValue) internal pure returns (uint256) {
        uint256 vSquared = rootValue.mulDown(rootValue);

        return vSquared.mulDown(vSquared);
    }
}
