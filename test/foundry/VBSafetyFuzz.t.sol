// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

/**
 * @notice Abstract base for virtual-balance safety fuzz tests. Concrete subclasses configure different pool
 * parameter regimes (price ratio, target position) via `_configureInitialPrices`, so the same properties are
 * exercised across the operating envelope. This guards against tests that pass only by chance at default
 * parameters.
 *
 * @dev Properties verified (from vb-zeroing-derivation.md):
 *
 * 1. bptDelta lower bound: After any successful proportional remove, the remaining supply is >=
 *    POOL_MINIMUM_TOTAL_SUPPLY (Section 1a).
 *
 * 2. VB/supply ratio preservation: Proportional removes preserve VB/supply within 1 unit of rounding per
 *    integer division (Section 1b).
 *
 * 3. VB-RB proportional scaling: Proportional removes scale real balances and virtual balances by the same
 *    factor (bptDelta / totalSupply). This is stronger than the original "non-zero VB implies non-zero RB"
 *    check, which was only meaningful at certain parameter combinations. Cross-multiplied form (to avoid
 *    division) verifies: RB_old * supply_new ~= RB_new * supply_old, and similarly for VBs.
 */
abstract contract VBSafetyFuzzBase is BaseReClammTest {
    using ArrayHelpers for *;

    function setUp() public virtual override {
        // Disable price shift so VBs only change through add/remove hooks, not time-based drift.
        setDailyPriceShiftExponent(0);
        _configureInitialPrices();
        super.setUp();
    }

    /// @dev Subclasses override to set `_initialMinPrice`, `_initialMaxPrice`, and `_initialTargetPrice` via
    /// `setInitializationPrices` before the pool is deployed. Empty in the default case.
    function _configureInitialPrices() internal virtual;

    // ---- bptDelta lower bound ----

    /**
     * @notice After any successful proportional remove, the remaining supply >= POOL_MINIMUM_TOTAL_SUPPLY.
     * @dev A near-total burn can also be rejected by the pool's ZeroVirtualBalance guard: when bptDelta is
     * small enough that `VB * bptDelta / totalSupply` truncates to zero, the pool reverts to prevent bricking.
     */
    function testBptDeltaLowerBound__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        vm.assume(lpBalance > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, lpBalance);

        uint256 bptDelta = poolTotalSupply - exactBptAmountIn;

        if (bptDelta < POOL_MINIMUM_TOTAL_SUPPLY) {
            vm.expectRevert();
        } else if (_wouldZeroAVirtualBalance(poolTotalSupply, bptDelta)) {
            vm.expectRevert(IReClammPool.ZeroVirtualBalance.selector);
        }

        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        uint256 newSupply = vault.totalSupply(pool);
        assertGe(newSupply, POOL_MINIMUM_TOTAL_SUPPLY, "Supply dropped below POOL_MINIMUM_TOTAL_SUPPLY");
        assertGe(bptDelta, 1, "bptDelta must be >= 1");
    }

    // ---- VB/supply ratio preservation ----

    /**
     * @notice VB/supply is preserved through proportional removes, up to 1 unit of rounding.
     * @dev Cross-multiplied form: |VB_old * supply_new - VB_new * supply_old| <= supply_old.
     */
    function testVbRatioPreservation__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        vm.assume(lpBalance > 0);
        uint256 maxRemove = _maxSafeRemove(poolTotalSupply);
        vm.assume(maxRemove > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, Math.min(lpBalance, maxRemove));

        (uint256[] memory vbBefore, ) = _computeCurrentVirtualBalances(pool);
        uint256 supplyBefore = poolTotalSupply;

        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        (uint256[] memory vbAfter, ) = _computeCurrentVirtualBalances(pool);
        uint256 supplyAfter = vault.totalSupply(pool);

        _assertRatioPreserved(vbBefore[0], vbAfter[0], supplyBefore, supplyAfter, "VBa");
        _assertRatioPreserved(vbBefore[1], vbAfter[1], supplyBefore, supplyAfter, "VBb");
    }

    // ---- VB-RB proportional scaling ----

    /**
     * @notice Real balances and virtual balances scale by the same proportional factor through proportional
     * removes. This replaces the weaker "non-zero VB implies non-zero RB" property, which was only meaningful
     * at certain parameter combinations. The underlying safety guarantee is that the remove hook and the
     * Vault's real-balance accounting apply the same `bptDelta / totalSupply` multiplier; this test verifies
     * that, independent of pool parameters.
     *
     * Cross-multiplied form (no division):
     *   |RB_old * supply_new - RB_new * supply_old| <= supply_old
     * bounds the rounding error at one integer division per balance.
     */
    function testVbRbProportionalScaling__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        vm.assume(lpBalance > 0);
        uint256 maxRemove = _maxSafeRemove(poolTotalSupply);
        vm.assume(maxRemove > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, Math.min(lpBalance, maxRemove));

        (, , uint256[] memory rbBefore, ) = vault.getPoolTokenInfo(pool);
        uint256 supplyBefore = poolTotalSupply;

        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        (, , uint256[] memory rbAfter, ) = vault.getPoolTokenInfo(pool);
        uint256 supplyAfter = vault.totalSupply(pool);

        // Real balances scale by the same proportional factor as virtual balances. Verify with the same
        // cross-multiplication bound used for VBs.
        _assertRatioPreserved(rbBefore[0], rbAfter[0], supplyBefore, supplyAfter, "RBa");
        _assertRatioPreserved(rbBefore[1], rbAfter[1], supplyBefore, supplyAfter, "RBb");
    }

    // ---- helpers ----

    function _assertRatioPreserved(
        uint256 oldVal,
        uint256 newVal,
        uint256 supplyOld,
        uint256 supplyNew,
        string memory label
    ) internal pure {
        if (oldVal == 0 || supplyNew == 0) {
            return;
        }

        uint256 crossOld = oldVal * supplyNew;
        uint256 crossNew = newVal * supplyOld;

        uint256 diff = crossOld > crossNew ? crossOld - crossNew : crossNew - crossOld;
        assertLe(diff, supplyOld, string.concat(label, " ratio deviation exceeds 1-unit rounding bound"));
    }

    /// @dev Returns true if scaling VBs by `bptDelta / totalSupply` would truncate either VB to zero.
    function _wouldZeroAVirtualBalance(uint256 totalSupply, uint256 bptDelta) internal view returns (bool) {
        (uint256[] memory vb, ) = _computeCurrentVirtualBalances(pool);
        return (vb[0] * bptDelta) / totalSupply == 0 || (vb[1] * bptDelta) / totalSupply == 0;
    }

    /// @dev Returns the maximum BPT that can be removed without hitting minimum supply or VB zeroing.
    function _maxSafeRemove(uint256 totalSupply) internal view returns (uint256) {
        uint256 maxFromSupply = totalSupply > POOL_MINIMUM_TOTAL_SUPPLY ? totalSupply - POOL_MINIMUM_TOTAL_SUPPLY : 0;

        (uint256[] memory vb, ) = _computeCurrentVirtualBalances(pool);
        uint256 minDeltaA = vb[0] > 0 ? (totalSupply + vb[0] - 1) / vb[0] : totalSupply;
        uint256 minDeltaB = vb[1] > 0 ? (totalSupply + vb[1] - 1) / vb[1] : totalSupply;
        uint256 minDelta = Math.max(minDeltaA, minDeltaB);

        uint256 maxFromVb = totalSupply > minDelta ? totalSupply - minDelta : 0;

        return Math.min(maxFromSupply, maxFromVb);
    }
}

/// @notice Default parameters: priceRatio = 4, target at geometric center.
contract VBSafetyFuzzDefaultTest is VBSafetyFuzzBase {
    function _configureInitialPrices() internal override {
        // Use inherited defaults.
    }
}

/// @notice Max price ratio (20), target near geometric center. Exercises the most asymmetric VB regime.
contract VBSafetyFuzzMaxRatioTest is VBSafetyFuzzBase {
    function _configureInitialPrices() internal override {
        // priceRatio = 20, target at geometric mean (sqrt(1 * 20) ~= 4.47)
        setInitializationPrices(1e18, 20e18, 4.47e18);
    }
}

/// @notice Min price ratio (just above 1.1). Tightest range; VBs are very large relative to real balances.
contract VBSafetyFuzzMinRatioTest is VBSafetyFuzzBase {
    function _configureInitialPrices() internal override {
        // priceRatio = 1.1, target at geometric mean (sqrt(1 * 1.1) ~= 1.0488)
        setInitializationPrices(1e18, 1.1e18, 1.0488e18);
    }
}

/// @notice Target near the upper edge of the range. Real balance of A is small relative to Va.
contract VBSafetyFuzzTargetNearMaxTest is VBSafetyFuzzBase {
    function _configureInitialPrices() internal override {
        // priceRatio = 4, target near maxPrice. _checkInitializationPrices bounds how close.
        setInitializationPrices(1000e18, 4000e18, 3800e18);
    }
}

/// @notice Target near the lower edge of the range. Real balance of B is small relative to Vb.
contract VBSafetyFuzzTargetNearMinTest is VBSafetyFuzzBase {
    function _configureInitialPrices() internal override {
        // priceRatio = 4, target near minPrice.
        setInitializationPrices(1000e18, 4000e18, 1100e18);
    }
}
