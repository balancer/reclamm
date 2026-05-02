// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolHelperMock } from "../../contracts/test/ReClammPoolHelperMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

/**
 * @notice Targeted tests for `ReClammPoolHelper._checkInitializationPrices`.
 *
 * The helper validates that a candidate `(balancesScaled18, virtualBalanceA, virtualBalanceB)` tuple produces
 * a spot price, minimum price, and maximum price that are each within `BALANCE_RATIO_AND_PRICE_TOLERANCE`
 * (0.01%) of the corresponding initialization parameters. This file exercises the function directly via
 * `ReClammPoolHelperMock`, covering:
 *   - Acceptance for valid initialization parameters across the factory-allowed price range (fuzz);
 *   - Behavior at and near the dust virtual-balance regime (`Va` close to 0 and to 1e9);
 *   - Dust real balances and zero / near-zero virtual balances (acceptable revert behavior);
 *   - Tolerance-band edges for spotPrice, currentMinPrice, and currentMaxPrice;
 *   - Revert ordering: spotPrice tolerance is checked before any range computation.
 */
contract ReClammPoolHelperPriceRangeTest is BaseReClammTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 internal constant _BALANCE_RATIO_AND_PRICE_TOLERANCE = 0.01e16; // 0.01%

    // Reference scenario for tolerance tests: an internally consistent state derived in `_refState`.
    uint256 internal constant _REF_BALANCE_A = 1000e18;
    uint256 internal constant _REF_BALANCE_B = 2_500_000e18;
    uint256 internal constant _REF_VIRTUAL_A = 1000e18;
    uint256 internal constant _REF_VIRTUAL_B = 1000e18;

    ReClammPoolHelperMock internal helperMock;

    function setUp() public override {
        super.setUp();
        helperMock = new ReClammPoolHelperMock(vault);
    }

    /* -------------------------------------------------------------------- */
    /*               Acceptance for valid initialization params             */
    /* -------------------------------------------------------------------- */

    /**
     * @dev For any `(minPrice, maxPrice, targetPrice)` triple inside the factory's allowed range, the
     * theoretical balances and virtual balances derived from `computeTheoreticalPriceRatioAndBalances` should
     * pass `_checkInitializationPrices`. This is the production happy path: the same derivation runs at
     * initialization, so this test pins the helper's acceptance of every valid input.
     */
    function testAcceptsValidInitializationParams__Fuzz(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice
    ) public view {
        minPrice = bound(minPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        maxPrice = bound(maxPrice, minPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        targetPrice = bound(
            targetPrice,
            minPrice + minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            maxPrice - minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );
        // Stay inside the factory cap on priceRatio; outside it is unreachable from valid pool creation.
        vm.assume(maxPrice.divDown(minPrice) <= 20e18);

        (uint256[] memory balancesScaled18, uint256 virtualBalanceA, uint256 virtualBalanceB, ) = ReClammMath
            .computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

        helperMock.checkInitializationPrices(
            balancesScaled18,
            minPrice,
            maxPrice,
            targetPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    /* -------------------------------------------------------------------- */
    /*                  Behavior across the Va = 1e9 boundary               */
    /* -------------------------------------------------------------------- */

    /**
     * @dev `(Va * Va) / 1e18` is 0 for `Va < 1e9` and 1 at `Va = 1e9`. The helper must produce comparable
     * prices across this boundary without reverting on an arithmetic panic. With prices set to whatever
     * `computePriceRange` actually returns, the tolerance check passes at all three sample points.
     */
    function testAcceptsAtVaBoundary() public view {
        uint256[3] memory vaCandidates = [uint256(1e9 - 1), uint256(1e9), uint256(1e9 + 1)];

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;
        uint256 virtualBalanceB = 1e18;

        for (uint256 i = 0; i < vaCandidates.length; ++i) {
            uint256 va = vaCandidates[i];
            (uint256 currentMinPrice, uint256 currentMaxPrice) = ReClammMath.computePriceRange(
                balancesScaled18,
                va,
                virtualBalanceB
            );
            uint256 spotPrice = (balancesScaled18[b] + virtualBalanceB).divDown(balancesScaled18[a] + va);

            helperMock.checkInitializationPrices(
                balancesScaled18,
                currentMinPrice,
                currentMaxPrice,
                spotPrice,
                va,
                virtualBalanceB
            );
        }
    }

    /**
     * @dev `Va < 1e9` is the regime where the previous helper's `Va.mulDown(Va)` floored to zero and divided
     * by it. The current helper routes through `computePriceRange`, which uses an algebraic rearrangement
     * robust to small `Va`. With prices set consistently, the helper accepts the input.
     */
    function testAcceptsAtDustVa() public view {
        uint256 virtualBalanceA = 5e8; // strictly between 0 and 1e9
        uint256 virtualBalanceB = 5e8;

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        (uint256 currentMinPrice, uint256 currentMaxPrice) = ReClammMath.computePriceRange(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB
        );
        uint256 spotPrice = (balancesScaled18[b] + virtualBalanceB).divDown(balancesScaled18[a] + virtualBalanceA);

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    /* -------------------------------------------------------------------- */
    /*                         Dust / invalid inputs                        */
    /* -------------------------------------------------------------------- */

    /**
     * @dev Va == 0 with mismatched init prices: spotPrice = (Bb+Vb)/(Ba+0) is wrong relative to targetPrice,
     * so the helper short-circuits on the spot-price tolerance check before reaching anything that would
     * divide by zero.
     */
    function testRevertsOnVaZeroWhenSpotPriceMismatched() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        // spotPrice = (1e18 + 1e18) / 1e18 = 2e18, well outside 0.01% of targetPrice = 1e18.
        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, 1e18, 0, 1e18);
    }

    /**
     * @dev Va == 0 with init prices arranged so spotPrice and currentMinPrice both pass. The price-range
     * computation then runs and reverts with an arithmetic panic when `computePriceRatio` divides by `Va`.
     * This is acceptable: a Va == 0 input never produces a successful initialization, and the factory's
     * `validatePoolParams` plus the balance-ratio check exclude it from production paths.
     */
    function testRevertsOnVaZeroWhenSpotPriceMatches() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 2e18;
        balancesScaled18[b] = 1e18;

        // With these inputs:
        //   spotPrice = (1e18 + 1e18) / (2e18 + 0) = 1e18 ; targetPrice = 1e18 (passes).
        //   invariant = (2e18 + 0).mulDown(1e18 + 1e18) = 4e18.
        //   currentMinPrice = (1e18 * 1e18) / 4e18 = 2.5e17 ; pass initMinPrice = 2.5e17 to match.
        uint256 initMinPrice = 2.5e17;
        uint256 initMaxPrice = 1e18; // Never reached.
        uint256 initTargetPrice = 1e18;

        vm.expectRevert(stdError.divisionError);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            initMinPrice,
            initMaxPrice,
            initTargetPrice,
            0,
            1e18
        );
    }

    /**
     * @dev Vb == 0 makes `currentMinPrice = 0`, which always falls outside the 0.01% tolerance band of any
     * non-zero initialization minPrice. The helper reverts with `WrongInitializationPrices`.
     */
    function testRevertsOnVbZero() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, 1e18, 1e18, 0);
    }

    /**
     * @dev Vb < 1e9 is within the regime where `Vb * Vb < 1e18`, so `currentMinPrice = (Vb*Vb) / L` floors
     * to 0. The tolerance check fails and the helper reverts with `WrongInitializationPrices`.
     */
    function testRevertsOnDustVb() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        uint256 va = 1e18;
        uint256 vb = 5e8; // < 1e9 -> Vb*Vb = 2.5e17 < 1e18, integer division by L floors to 0.

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, 1e18, va, vb);
    }

    /**
     * @dev Very small real balances. With Ra = Rb = 1 wei and Va = Vb = 1e18, the invariant is dominated by
     * the virtual balances and the prices are near 1.0. The helper accepts this state when the init prices
     * match what `computePriceRange` returns.
     */
    function testAcceptsTinyRealBalances() public view {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1;
        balancesScaled18[b] = 1;

        uint256 va = 1e18;
        uint256 vb = 1e18;
        (uint256 currentMinPrice, uint256 currentMaxPrice) = ReClammMath.computePriceRange(balancesScaled18, va, vb);
        uint256 spotPrice = (balancesScaled18[b] + vb).divDown(balancesScaled18[a] + va);

        helperMock.checkInitializationPrices(balancesScaled18, currentMinPrice, currentMaxPrice, spotPrice, va, vb);
    }

    /* -------------------------------------------------------------------- */
    /*                       Tolerance-band edge cases                      */
    /* -------------------------------------------------------------------- */

    /**
     * @dev Build a self-consistent `(balances, Va, Vb)` tuple, read the prices the helper actually computes,
     * then perturb the initialization prices to land just inside or just outside the 0.01% tolerance.
     */
    function _refState()
        internal
        pure
        returns (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        )
    {
        balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = _REF_BALANCE_A;
        balancesScaled18[b] = _REF_BALANCE_B;
        virtualBalanceA = _REF_VIRTUAL_A;
        virtualBalanceB = _REF_VIRTUAL_B;

        (currentMinPrice, currentMaxPrice) = ReClammMath.computePriceRange(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB
        );
        spotPrice = (balancesScaled18[b] + virtualBalanceB).divDown(balancesScaled18[a] + virtualBalanceA);
    }

    /**
     * @dev `priceLowerBound = initMinPrice * (1 - tolerance)`,
     * `priceUpperBound = initMinPrice * (1 + tolerance)`. Setting
     * `initMinPrice = currentMinPrice / (1 + tolerance) + 1 wei` puts `currentMinPrice` just inside the upper
     * bound: the check passes.
     */
    function testAcceptsMinPriceJustInsideTolerance() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        uint256 initMinPrice = currentMinPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) + 1;

        helperMock.checkInitializationPrices(
            balancesScaled18,
            initMinPrice,
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMinPriceJustOutsideTolerance() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        // Push initMinPrice down so currentMinPrice falls above the 0.01% upper bound.
        uint256 initMinPrice = currentMinPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) - 1e6;

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            initMinPrice,
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testAcceptsMaxPriceJustInsideTolerance() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        uint256 initMaxPrice = currentMaxPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) + 1;

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            initMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMaxPriceJustOutsideTolerance() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        uint256 initMaxPrice = currentMaxPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) - 1e6;

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            initMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testAcceptsTargetPriceJustInsideTolerance() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        uint256 initTargetPrice = spotPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) + 1;

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            initTargetPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsTargetPriceJustOutsideTolerance() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        uint256 initTargetPrice = spotPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) - 1e6;

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            initTargetPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    /* -------------------------------------------------------------------- */
    /*                           Revert ordering                            */
    /* -------------------------------------------------------------------- */

    /**
     * @dev The helper's first action is comparing spotPrice against the initialization targetPrice. If that
     * check fails, the function returns before invoking `computePriceRange`, even when the supplied virtual
     * balances would otherwise cause an arithmetic panic in the range computation. This pins the ordering.
     */
    function testChecksSpotPriceBeforeRangeComputation() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        // spotPrice = (1e18 + 1e18) / (1e18 + 0) = 2e18, far outside 0.01% of targetPrice = 1e18. The helper
        // reverts with WrongInitializationPrices before reaching the price-range computation that would
        // otherwise revert on division by Va == 0.
        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, 1e18, 0, 1e18);
    }
}
