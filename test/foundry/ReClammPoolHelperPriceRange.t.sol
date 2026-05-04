// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPoolHelperMock } from "../../contracts/test/ReClammPoolHelperMock.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

/**
 * @notice Targeted tests for `ReClammPoolHelper._checkInitializationPrices`.
 * @dev  The helper validates that a candidate `(balancesScaled18, virtualBalanceA, virtualBalanceB)` tuple produces
 * a spot price, minimum price, and maximum price that are each within `BALANCE_RATIO_AND_PRICE_TOLERANCE`: (0.01%)
 * of the corresponding initialization parameters. This file exercises the function directly via
 * `ReClammPoolHelperMock`, covering:
 *   - Acceptance for valid initialization parameters across the factory-allowed price range (fuzz);
 *   - Behavior at and near the dust virtual-balance regime (`Va` close to 0 and to 1e9);
 *   - Dust real balances and zero / near-zero virtual balances (acceptable revert behavior);
 *   - Tolerance-band edges on both sides for spotPrice, currentMinPrice, and currentMaxPrice;
 *   - Revert ordering: spotPrice tolerance is checked before any range computation.
 */
contract ReClammPoolHelperPriceRangeTest is BaseReClammTest {
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

    // Valid Initialization Tests

    /**
     * @dev For any `(minPrice, maxPrice, targetPrice)` triple inside the factory's allowed range, the theoretical
     * balances and virtual balances derived from `computeTheoreticalPriceRatioAndBalances` must pass
     * `_checkInitializationPrices`. This is the production happy path: the same derivation runs at initialization,
     * so this test pins acceptance of every reachable input.
     *
     * Bounds the priceRatio directly into the production-valid regime ([1.0001e18, 20e18]) so every fuzz sample
     * exercises the helper rather than getting filtered out by `vm.assume`.
     */
    function testAcceptsValidInitializationParams__Fuzz(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice
    ) public view {
        minPrice = bound(minPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));

        uint256 maxAllowedByRatio = minPrice.mulDown(20e18);
        uint256 maxUpperBound = maxAllowedByRatio < _MAX_PRICE ? maxAllowedByRatio : _MAX_PRICE;
        maxPrice = bound(maxPrice, minPrice.mulUp(_MIN_PRICE_RATIO), maxUpperBound);

        targetPrice = bound(
            targetPrice,
            minPrice + minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            maxPrice - minPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

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

    // Va = 1e9 Boundary Tests

    // The helper previously had a multiplication that overflowed when Va < 1e9, so this is a natural edge case.

    /**
     * @dev `(Va * Va) / 1e18` is 0 for `Va < 1e9` and 1 at `Va = 1e9`. The helper must produce comparable prices
     * across this boundary without reverting on an arithmetic panic. With prices set to whatever `computePriceRange`
     * actually returns, the tolerance check passes at all three sample points.
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
     * @dev `Va < 1e9` is the regime where the previous helper's `Va.mulDown(Va)` floored to zero and divided by it.
     * The current helper routes through `computePriceRange`, which uses an algebraic rearrangement robust to small
     * `Va`. Vb is set large enough that `currentMinPrice` and `currentMaxPrice` are nonzero, so the tolerance check
     * exercises real values rather than the trivial `0 == 0` case.
     */
    function testAcceptsAtDustVa() public view {
        uint256 virtualBalanceA = 5e8; // strictly between 0 and 1e9
        uint256 virtualBalanceB = 1e18; // large enough that Vb*Vb >> invariant, so currentMinPrice > 0

        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;

        (uint256 currentMinPrice, uint256 currentMaxPrice) = ReClammMath.computePriceRange(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB
        );
        // Sanity: prices are nonzero, so the tolerance check is meaningful.
        assertGt(currentMinPrice, 0, "currentMinPrice should be nonzero in this regime");
        assertGt(currentMaxPrice, 0, "currentMaxPrice should be nonzero in this regime");

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

    // Dust / Invalid Input tests

    /**
     * @dev Va == 0 with init prices arranged so spotPrice passes and the implied minPrice would match. The helper then
     * reaches `computePriceRange`, which reverts with an arithmetic panic when `computePriceRatio` divides by Va.
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
        //   The implied currentMinPrice would be (1e18 * 1e18) / 4e18 = 2.5e17, which matches initMinPrice
        //   below; but the helper never reaches that comparison because computePriceRatio divides by
        //   Va == 0 first and panics.
        vm.expectRevert(stdError.divisionError);
        helperMock.checkInitializationPrices(balancesScaled18, 2.5e17, 1e18, 1e18, 0, 1e18);
    }

    /**
     * @dev Vb == 0 with spotPrice arranged to pass. The helper reaches `computePriceRange`, which reverts with an
     * arithmetic panic inside `computePriceRatio` when it divides `balancesScaled18[b]` by Vb.
     *
     * This is acceptable: a Vb == 0 input is excluded by production validation; the helper just needs to not silently
     * accept it.
     */
    function testRevertsOnVbZero() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;
        uint256 va = 1e18;
        uint256 vb = 0;

        uint256 spotPrice = (balancesScaled18[b] + vb).divDown(balancesScaled18[a] + va);

        vm.expectRevert(stdError.divisionError);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, spotPrice, va, vb);
    }

    /**
     * @dev Vb < 1e9 puts `Vb * Vb < 1e18`, so `currentMinPrice = (Vb*Vb) / L` floors to 0. With spotPrice arranged to
     * pass, the helper reaches the minPrice tolerance check, which fails because 0 falls outside the 0.01% band of any
     * non-zero `initMinPrice`. Reverts with `WrongInitializationPrices`.
     */
    function testRevertsOnDustVb() public {
        uint256[] memory balancesScaled18 = new uint256[](2);
        balancesScaled18[a] = 1e18;
        balancesScaled18[b] = 1e18;
        uint256 va = 1e18;
        uint256 vb = 5e8; // < 1e9 -> Vb*Vb = 2.5e17 < 1e18, integer division by L floors to 0.

        uint256 spotPrice = (balancesScaled18[b] + vb).divDown(balancesScaled18[a] + va);

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(balancesScaled18, 1e18, 1e18, spotPrice, va, vb);
    }

    /**
     * @dev Very small real balances. With Ra = Rb = 1 wei and Va = Vb = 1e18, the invariant is dominated by the
     * virtual balances and the prices are near 1.0. The helper accepts this state when the init prices match what
     * `computePriceRange` returns.
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

    // ---- spotPrice (compared against initTargetPrice)

    function testAcceptsSpotPriceJustInsideUpperBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            _justInsideUpper(spotPrice),
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsSpotPriceJustOutsideUpperBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            _justOutsideUpper(spotPrice),
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testAcceptsSpotPriceJustInsideLowerBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            _justInsideLower(spotPrice),
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsSpotPriceJustOutsideLowerBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            currentMaxPrice,
            _justOutsideLower(spotPrice),
            virtualBalanceA,
            virtualBalanceB
        );
    }

    // ---- currentMinPrice (compared against initMinPrice) ---------------

    function testAcceptsMinPriceJustInsideUpperBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            _justInsideUpper(currentMinPrice),
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMinPriceJustOutsideUpperBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            _justOutsideUpper(currentMinPrice),
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testAcceptsMinPriceJustInsideLowerBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            _justInsideLower(currentMinPrice),
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMinPriceJustOutsideLowerBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            _justOutsideLower(currentMinPrice),
            currentMaxPrice,
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    // ---- currentMaxPrice (compared against initMaxPrice) ---------------

    function testAcceptsMaxPriceJustInsideUpperBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            _justInsideUpper(currentMaxPrice),
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMaxPriceJustOutsideUpperBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            _justOutsideUpper(currentMaxPrice),
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testAcceptsMaxPriceJustInsideLowerBound() public view {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            _justInsideLower(currentMaxPrice),
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    function testRejectsMaxPriceJustOutsideLowerBound() public {
        (
            uint256[] memory balancesScaled18,
            uint256 virtualBalanceA,
            uint256 virtualBalanceB,
            uint256 currentMinPrice,
            uint256 currentMaxPrice,
            uint256 spotPrice
        ) = _refState();

        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        helperMock.checkInitializationPrices(
            balancesScaled18,
            currentMinPrice,
            _justOutsideLower(currentMaxPrice),
            spotPrice,
            virtualBalanceA,
            virtualBalanceB
        );
    }

    /**
     * @dev The helper's first action is comparing spotPrice against the initialization targetPrice. If that check
     * fails, the function returns before invoking `computePriceRange`, even when the supplied virtual balances would
     * otherwise cause an arithmetic panic in the range computation. This pins the ordering.
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

    // Support tolerance-band Edge Cases

    /**
     * @dev Build a self-consistent `(balances, Va, Vb)` tuple, read the prices the helper actually computes, then
     * perturb the initialization prices to land just inside or just outside each side of the 0.01% tolerance band.
     *
     * `_comparePrice` rejects when `currentPrice < initPrice * (1 - tol)` or
     * `currentPrice > initPrice * (1 + tol)`. So:
     *   - Just inside upper bound: `initPrice = currentPrice / (1 + tol) + 1`.
     *   - Just outside upper bound: `initPrice = currentPrice / (1 + tol) - 1e6`.
     *   - Just inside lower bound: `initPrice = currentPrice / (1 - tol) - 1`.
     *   - Just outside lower bound: `initPrice = currentPrice / (1 - tol) + 1e6`.
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

    function _justInsideUpper(uint256 currentPrice) internal pure returns (uint256) {
        return currentPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) + 1;
    }

    function _justOutsideUpper(uint256 currentPrice) internal pure returns (uint256) {
        return currentPrice.divDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE) - 1e6;
    }

    function _justInsideLower(uint256 currentPrice) internal pure returns (uint256) {
        return currentPrice.divUp(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE) - 1;
    }

    function _justOutsideLower(uint256 currentPrice) internal pure returns (uint256) {
        return currentPrice.divUp(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE) + 1e6;
    }
}
