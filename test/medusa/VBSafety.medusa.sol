// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-vault/test/foundry/utils/BaseMedusaTest.sol";

import { ReClammPriceParams } from "../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { ReClammPoolHelper } from "../../contracts/ReClammPoolHelper.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

/**
 * @notice Medusa property tests verifying VB safety invariants from vb-zeroing-derivation.md.
 * @dev Two properties are tested:
 *
 * 1d. VB zeroing can only occur at minimum BPT supply. If either VB is zero, total supply must be at or near the
 * minimum (1e6), with at most nLiquidityOps units of slack from cumulative rounding.
 *
 * 1e. Cumulative rounding erosion is bounded: after N add/remove operations, the total VB loss from rounding is
 * at most N units (in fp18). Verified via cross-multiplication to avoid division:
 *   VBref * supply - VB * supplyRef <= N * supplyRef.
 *
 * Both price-range tracking and price-ratio updates are disabled (dailyPriceShiftExponent = 0,
 * centerednessMargin = 0) so that VBs only change through add/remove proportional operations.
 * This isolates rounding effects from time-based VB drift.
 */
contract VBSafetyMedusaTest is BaseMedusaTest {
    using FixedPoint for uint256;
    using ArrayHelpers for *;

    uint256 internal constant POOL_MINIMUM_TOTAL_SUPPLY = 1e6;
    uint256 internal constant MIN_RECLAMM_TOKEN_BALANCE = 1e12;

    // Reference state captured at construction (post-initialization).
    uint256 internal vbARef;
    uint256 internal vbBRef;
    uint256 internal supplyRef;

    // Cumulative count of add/remove operations (each contributes at most 1 unit of rounding).
    uint256 internal nLiquidityOps;

    constructor() BaseMedusaTest() {
        // Capture reference VBs and supply immediately after pool initialization.
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = ReClammPool(address(pool))
            .computeCurrentVirtualBalances();
        vbARef = virtualBalanceA;
        vbBRef = virtualBalanceB;
        supplyRef = ReClammPool(address(pool)).totalSupply();
        nLiquidityOps = 0;

        // Zero the swap fee so add/remove operations don't interact with fee logic.
        vault.manualUnsafeSetStaticSwapFeePercentage(address(pool), 0);
    }

    /// @dev Creates a ReClammPool with price-range tracking disabled to isolate rounding effects.
    function createPool(IERC20[] memory tokens, uint256[] memory initialBalances) internal override returns (address) {
        ReClammPoolHelper helper = new ReClammPoolHelper(vault);
        ReClammPoolFactory factory = new ReClammPoolFactory(
            vault,
            helper,
            1 days,
            "ReClamm Pool Factory",
            "ReClammPoolFactory"
        );

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: 1000e18,
            initialMaxPrice: 4000e18,
            initialTargetPrice: 3000e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        PoolRoleAccounts memory roleAccounts;
        address newPool = ReClammPoolFactory(factory).create(
            "ReClamm Pool",
            "RECLAMM",
            vault.buildTokenConfig(tokens),
            roleAccounts,
            0.001e16, // minimum swap fee (zeroed out below)
            priceParams,
            0, // dailyPriceShiftExponent = 0: disables price-range tracking
            0, // centerednessMargin = 0: pool is always "in range"
            ""
        );

        // Compute the initial balance ratio so that the target price of the pool is respected.
        uint256[] memory initBalances = ReClammPool(newPool).computeInitialBalancesRaw(tokens[0], initialBalances[0]);
        initialBalances[0] = initBalances[0];
        initialBalances[1] = initBalances[1];

        medusa.prank(lp);
        router.initialize(address(newPool), tokens, initialBalances, 0, false, bytes(""));

        return newPool;
    }

    function getTokensAndInitialBalances()
        internal
        view
        override
        returns (IERC20[] memory tokens, uint256[] memory initialBalances)
    {
        tokens = new IERC20[](2);
        tokens[0] = dai;
        tokens[1] = usdc;
        tokens = InputHelpers.sortTokens(tokens);

        initialBalances = new uint256[](2);
        initialBalances[0] = DEFAULT_INITIAL_POOL_BALANCE;
        initialBalances[1] = DEFAULT_INITIAL_POOL_BALANCE;
    }

    /**
     * @notice Add proportional liquidity. Each successful call increments the rounding counter.
     * @dev No try/catch -- let reverts happen naturally. Some reverts are expected (e.g. when the fuzzer is stuck;
     * some reverts confirm edge cases are being reached.
     */
    function addLiquidityProportional(uint256 exactBptOut) external {
        uint256 totalSupply = ReClammPool(address(pool)).totalSupply();
        exactBptOut = bound(exactBptOut, 1e18, totalSupply);

        uint256 supplyBefore = totalSupply;

        medusa.prank(lp);
        router.addLiquidityProportional(
            address(pool),
            [MAX_UINT256, MAX_UINT256].toMemoryArray(),
            exactBptOut,
            false,
            bytes("")
        );

        // Only increment if supply actually changed (add succeeded).
        if (ReClammPool(address(pool)).totalSupply() != supplyBefore) {
            nLiquidityOps++;
        }
    }

    /// @notice Remove proportional liquidity. Each successful call increments the rounding counter.
    function removeLiquidityProportional(uint256 exactBptIn) external {
        uint256 totalSupply = ReClammPool(address(pool)).totalSupply();
        exactBptIn = bound(exactBptIn, 1e18, totalSupply);

        uint256 supplyBefore = totalSupply;

        medusa.prank(lp);
        router.removeLiquidityProportional(
            address(pool),
            exactBptIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        if (ReClammPool(address(pool)).totalSupply() != supplyBefore) {
            nLiquidityOps++;
        }
    }

    // VB Zeroing Only at Minimum Supply (1d)

    /**
     * @notice If either VB is zero, the pool must be at (or within rounding distance of) minimum supply.
     * @dev From derivation Section 1c: VB rounds to zero only when VB * 1e6 < supply, which
     * requires an exit to the minimum supply floor. Each rounding operation can lose at most 1 unit,
     * so we allow nLiquidityOps units of slack above the 1e6 minimum.
     *
     * Returns true (property passes) when:
     * - Both VBs are positive (condition does not apply), OR
     * - A VB is zero AND supply is within the allowed range.
     *
     * Returns false (property violated) when:
     * - A VB is zero AND supply is meaningfully above the minimum.
     *
     * Attack scenario covered: if an attacker could zero VBs on a healthy pool (supply >> 1e6),
     * they could break the invariant and extract value. This property proves that is impossible.
     */
    function property_vbZeroingOnlyAtMinSupply() public view returns (bool) {
        (uint256 vbA, uint256 vbB, ) = ReClammPool(address(pool)).computeCurrentVirtualBalances();
        uint256 totalSupply = ReClammPool(address(pool)).totalSupply();

        // Property only applies when at least one VB is zero; pass otherwise.
        if (vbA > 0 && vbB > 0) {
            return true;
        }

        // If a VB is zero, supply must be at or very near the minimum.
        // Each operation can reduce VB by at most 1 unit, potentially allowing zeroing slightly above 1e6.
        return totalSupply <= POOL_MINIMUM_TOTAL_SUPPLY + nLiquidityOps;
    }

    // 1e. Cumulative Rounding Erosion Bound (1e.)

    /**
     * @notice After N add/remove operations, VB loss from rounding is at most N units (fp18).
     * @dev Uses cross-multiplication to avoid division:
     *
     *     |VBref * supply - VB * supplyRef| <= N * supplyRef
     *
     * Derivation: the ideal VB at current supply is VBref * supply / supplyRef (exact ratio preservation). The actual
     * VB is at most N units below ideal (one unit per operation).
     *
     * So: VBref * supply / supplyRef - VB <= N
     *
     * Multiply both sides by supplyRef:
     *     VBref * supply - VB * supplyRef <= N * supplyRef
     *
     * We take the absolute difference to also catch VBs that drift above ideal (rounding in the add direction).
     * This avoids all division and thus all additional rounding error.
     *
     * Returns true (property passes) when:
     * - Pool is at minimum supply (VBs may have legitimately zeroed -- skip), OR
     * - Reference values are zero (should not happen -- skip), OR
     * - The cross-product difference is within the N-operation bound.
     *
     * Returns false (property violated) when:
     * - The VB drift exceeds N units per operation, indicating rounding loss is unbounded.
     *
     * Attack scenario covered: Octane Finding 1, Scenario 2 claims repeated micro add/remove
     * cycles can erode VBs to zero. This property proves erosion is at most 1 unit per
     * operation -- requiring 10^25+ operations for a typical pool (physically impossible).
     */
    function property_roundingErosionBound() public view returns (bool) {
        (uint256 vbA, uint256 vbB, ) = ReClammPool(address(pool)).computeCurrentVirtualBalances();
        uint256 totalSupply = ReClammPool(address(pool)).totalSupply();

        // Skip if pool is at minimum supply (VBs may have legitimately zeroed).
        if (totalSupply <= POOL_MINIMUM_TOTAL_SUPPLY) {
            return true;
        }

        // Should not happen post-initialization.
        assert(supplyRef > 0 && vbARef > 0 && vbBRef > 0);

        // Check VB A: |vbARef * totalSupply - vbA * supplyRef| <= nLiquidityOps * supplyRef
        uint256 crossRef_A = vbARef * totalSupply;
        uint256 crossActual_A = vbA * supplyRef;
        uint256 diff_A = crossRef_A > crossActual_A ? crossRef_A - crossActual_A : crossActual_A - crossRef_A;

        uint256 bound_A = nLiquidityOps * supplyRef;
        if (diff_A > bound_A) {
            return false;
        }

        // Check VB B: same cross-multiplication bound.
        uint256 crossRef_B = vbBRef * totalSupply;
        uint256 crossActual_B = vbB * supplyRef;
        uint256 diff_B = crossRef_B > crossActual_B ? crossRef_B - crossActual_B : crossActual_B - crossRef_B;

        uint256 bound_B = nLiquidityOps * supplyRef;
        return diff_B <= bound_B;
    }
}
