// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

/**
 * @notice Regression test for the long-idle bricked-pool scenario.
 * @dev Reproduces the path described in the Cantina issue: drain one side, idle for ~12 days, then do a swap.
 * Without the `_MIN_VIRTUAL_BALANCE` guard, the second swap panics with division by zero (panic 0x12) inside
 * `computePriceRange.maxPrice`. With the guard, the second swap reverts cleanly with `VirtualBalanceTooLow`.
 * (At this point the pool is permanently bricked.)
 */
contract ReClammVirtualBalanceGuardTest is BaseReClammTest {
    IERC20 internal tokenA;
    IERC20 internal tokenB;

    function setUp() public override {
        poolInitAmount = 1e12;
        super.setUp();

        tokenA = daiIdx == 0 ? IERC20(address(dai)) : IERC20(address(usdc));
        tokenB = daiIdx == 0 ? IERC20(address(usdc)) : IERC20(address(dai));
    }

    function testLongIdleBrickedPoolGuard() public {
        (, , uint256[] memory balancesBeforeDrain, ) = vault.getPoolTokenInfo(pool);

        // Drain all of token A by swapping token B in.
        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokenB,
            tokenA,
            balancesBeforeDrain[0],
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Long idle period that drives the lazy virtual balance update down toward the floor.
        vm.warp(block.timestamp + 11 days + 22 hours);

        // First swap (1 wei). This succeeds and commits a degraded virtual balance to storage.
        // The input VBs are still healthy at this point, so the guard at the top of `computeCurrentVirtualBalances`
        // passes; the "decayed" result after the idle period is what gets persisted and trips the guard on
        // subsequent calls.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, tokenB, tokenA, 1, 0, MAX_UINT256, false, bytes(""));

        (uint256 vaAfterFirstSwap, uint256 vbAfterFirstSwap) = ReClammPool(pool).getLastVirtualBalances();
        assertLt(vaAfterFirstSwap, 1e12, "Va should have decayed below the safe floor");
        assertGe(vbAfterFirstSwap, 1e12, "Vb should still be above the safe floor");

        // A short additional idle period.
        vm.warp(block.timestamp + 1 hours);

        // Second swap: the stored Va is now below `_MIN_VIRTUAL_BALANCE`, so the guard fires with a clean error
        // instead of panicking with division by zero in `computePriceRange`.
        vm.expectRevert(ReClammMath.VirtualBalanceTooLow.selector);
        ReClammPool(pool).computeCurrentVirtualBalances();

        vm.prank(alice);
        vm.expectRevert(ReClammMath.VirtualBalanceTooLow.selector);
        router.swapSingleTokenExactIn(pool, tokenB, tokenA, 1, 0, MAX_UINT256, false, bytes(""));
    }
}
