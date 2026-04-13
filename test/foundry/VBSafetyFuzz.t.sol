// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

/**
 * @notice Foundry fuzz tests verifying virtual balance safety properties from vb-zeroing-derivation.md.
 * @dev These tests mechanically verify the key results of the VB zeroing derivation.
 *
 * The Vault's minimum BPT supply guarantee (supply >= 1e6) is the foundation for all VB safety. bptDelta
 * (post-burn supply) is always >= 1e6 for any successful remove (Section 1a of the derivation).
 *
 * VB/supply ratio is preserved through proportional operations, with at most 1 unit of rounding error per
 * integer division (Section 1b of the derivation).
 *
 * Positive VBs imply economic value: if both VBs > 0, at least one real balance > 0. VBs cannot be positive
 * while the pool holds no tokens (Section 1d of the derivation).
 */
contract VBSafetyFuzzTest is BaseReClammTest {
    using ArrayHelpers for *;

    function setUp() public virtual override {
        // Disable price shift so VBs only change through add/remove hooks, not time-based drift.
        setDailyPriceShiftExponent(0);
        super.setUp();
    }

    // bptDelta Lower Bound

    /**
     * @notice After any successful proportional remove, the remaining supply >= POOL_MINIMUM_TOTAL_SUPPLY.
     * @dev This is the Vault-level guarantee that the derivation (Section 1c) depends on: VBs can only round to zero
     * when supply equals the permanently locked minimum (1e6).
     *
     * A near-total burn can also be rejected by the pool's ZeroVirtualBalance guard: when bptDelta is small
     * enough that `VB * bptDelta / totalSupply` truncates to zero, the pool reverts to prevent bricking.
     */
    function testBptDeltaLowerBound__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        // LP must have BPT to remove.
        vm.assume(lpBalance > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, lpBalance);

        uint256 bptDelta = poolTotalSupply - exactBptAmountIn;

        if (bptDelta < POOL_MINIMUM_TOTAL_SUPPLY) {
            // The Vault should revert when the burn would violate minimum supply.
            vm.expectRevert();
        } else if (_wouldZeroAVirtualBalance(poolTotalSupply, bptDelta)) {
            // The pool's ZeroVirtualBalance guard reverts when VB scaling truncates to zero.
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

        // If we reach here, the remove succeeded. Verify the post-conditions.
        uint256 newSupply = vault.totalSupply(pool);

        // Core guarantee: supply never drops below the minimum.
        assertGe(newSupply, POOL_MINIMUM_TOTAL_SUPPLY, "Supply dropped below POOL_MINIMUM_TOTAL_SUPPLY");

        // Derived: bptDelta >= 1 (the pool cannot be fully drained).
        assertGe(bptDelta, 1, "bptDelta must be >= 1");
    }

    // VB Ratio Preservation

    /**
     * @notice VB/supply is preserved through proportional removes, up to 1 unit of rounding per integer division.
     * @dev This is discussed in derivation Section 1b.
     *
     * Cross-multiply to verify without division:
     *   VB_old * supply_new ≈ VB_new * supply_old
     * The maximum deviation from one floor() operation is:
     *   |VB_old * supply_new - VB_new * supply_old| <= supply_old
     * because floor(VB * delta / supply) drops at most (supply-1)/supply of one VB unit,
     * and VB * delta / supply - floor(VB * delta / supply) < 1, so the cross-product difference is < supply_old.
     *
     */
    function testVbRatioPreservation__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        vm.assume(lpBalance > 0);

        // Ensure the remove won't violate minimum supply or trigger ZeroVirtualBalance.
        uint256 maxRemove = _maxSafeRemove(poolTotalSupply);
        vm.assume(maxRemove > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, Math.min(lpBalance, maxRemove));

        // Record pre-remove state.
        (uint256[] memory vbBefore, ) = _computeCurrentVirtualBalances(pool);
        uint256 supplyBefore = poolTotalSupply;

        // Perform proportional remove.
        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        // Record post-remove state.
        (uint256[] memory vbAfter, ) = _computeCurrentVirtualBalances(pool);
        uint256 supplyAfter = vault.totalSupply(pool);

        // Verify ratio preservation for each VB via cross-multiplication.
        // VB_old * supply_new should be close to VB_new * supply_old.
        _assertRatioPreserved(vbBefore[0], vbAfter[0], supplyBefore, supplyAfter, "VBa");
        _assertRatioPreserved(vbBefore[1], vbAfter[1], supplyBefore, supplyAfter, "VBb");
    }

    function _assertRatioPreserved(
        uint256 vbOld,
        uint256 vbNew,
        uint256 supplyOld,
        uint256 supplyNew,
        string memory label
    ) internal pure {
        if (vbOld == 0 || supplyNew == 0) {
            return;
        }

        uint256 crossOld = vbOld * supplyNew;
        uint256 crossNew = vbNew * supplyOld;

        uint256 diff = crossOld > crossNew ? crossOld - crossNew : crossNew - crossOld;

        // Maximum cross-product deviation from one floor() operation is (supply_old - 1).
        // We use supply_old as the bound (inclusive) for simplicity.
        assertLe(diff, supplyOld, string.concat(label, " ratio deviation exceeds 1-unit rounding bound"));
    }

    // VB Non-Zero Implies Economic Value

    /**
     * @notice If both VBs are positive after any operation, at least one real balance is also positive.
     * @dev This verifies that VBs cannot be positive while the pool holds no real tokens (derivation Section 1d:
     * VB zeroing implies real balance zeroing).
     */
    function testVbNonZeroImpliesEconomicValue__Fuzz(uint256 exactBptAmountIn) public {
        uint256 poolTotalSupply = vault.totalSupply(pool);
        uint256 lpBalance = vault.balanceOf(pool, lp);

        vm.assume(lpBalance > 0);

        // Ensure the remove won't violate minimum supply or trigger ZeroVirtualBalance.
        uint256 maxRemove = _maxSafeRemove(poolTotalSupply);
        vm.assume(maxRemove > 0);
        exactBptAmountIn = bound(exactBptAmountIn, 1, Math.min(lpBalance, maxRemove));

        // Perform proportional remove.
        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        // Read post-operation state.
        (uint256[] memory vbAfter, ) = _computeCurrentVirtualBalances(pool);
        (, , uint256[] memory realBalancesAfter, ) = vault.getPoolTokenInfo(pool);

        // Property: if both VBs are positive, the pool must hold real tokens.
        if (vbAfter[0] > 0 && vbAfter[1] > 0) {
            assertTrue(
                realBalancesAfter[0] > 0 || realBalancesAfter[1] > 0,
                "Both VBs positive but all real balances are zero -- pool has phantom value"
            );
        }
    }

    /// @dev Returns true if scaling VBs by `bptDelta / totalSupply` would truncate either VB to zero.
    function _wouldZeroAVirtualBalance(uint256 totalSupply, uint256 bptDelta) internal view returns (bool) {
        (uint256[] memory vb, ) = _computeCurrentVirtualBalances(pool);
        return (vb[0] * bptDelta) / totalSupply == 0 || (vb[1] * bptDelta) / totalSupply == 0;
    }

    /// @dev Returns the maximum BPT that can be removed without hitting minimum supply or VB zeroing.
    function _maxSafeRemove(uint256 totalSupply) internal view returns (uint256) {
        // Start from the minimum-supply bound.
        uint256 maxFromSupply = totalSupply > POOL_MINIMUM_TOTAL_SUPPLY ? totalSupply - POOL_MINIMUM_TOTAL_SUPPLY : 0;

        // Additionally, bptDelta must be large enough that VB * bptDelta / totalSupply > 0.
        // That means bptDelta > totalSupply / VB, i.e., exactBptAmountIn < totalSupply - ceil(totalSupply / VB).
        (uint256[] memory vb, ) = _computeCurrentVirtualBalances(pool);
        uint256 minDeltaA = vb[0] > 0 ? (totalSupply + vb[0] - 1) / vb[0] : totalSupply;
        uint256 minDeltaB = vb[1] > 0 ? (totalSupply + vb[1] - 1) / vb[1] : totalSupply;
        uint256 minDelta = Math.max(minDeltaA, minDeltaB);

        uint256 maxFromVb = totalSupply > minDelta ? totalSupply - minDelta : 0;

        return Math.min(maxFromSupply, maxFromVb);
    }
}
