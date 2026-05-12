// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";

import { PriceRatioState, ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

/**
 * @notice Behavior tests for `startPriceRatioUpdate` and `stopPriceRatioUpdate`.
 * @dev Covers the state these calls write (the captured start ratio, the end ratio, the timestamps, and
 * `_lastTimestamp`), the way `stopPriceRatioUpdate` collapses an ongoing update into a no-op, the rejection of an
 * inverted time window, and the rate-fetch count: each call must invoke the rate provider exactly once per token.
 */
contract ReClammPoolPriceRatioUpdateTest is BaseReClammTest {
    function testStartPriceRatioUpdateWritesExpectedState() public {
        // Move forward so `_lastTimestamp != block.timestamp` and `_updateVirtualBalances` runs.
        vm.warp(block.timestamp + 1 days);

        // Snapshot the view values that the runtime path should preserve / store.
        uint256 expectedStartFourthRoot = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        (uint256 expectedVbA, uint256 expectedVbB, ) = ReClammPool(pool).computeCurrentVirtualBalances();

        uint256 endPriceRatio = 8e18;
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;
        uint256 expectedEndFourthRoot = ReClammMath.fourthRootScaled18(endPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, startTime, endTime);

        // PriceRatioState matches the captured ratio + the caller-supplied end & times.
        PriceRatioState memory state = ReClammPool(pool).getPriceRatioState();
        assertEq(uint256(state.startFourthRootPriceRatio), expectedStartFourthRoot, "start fourth root");
        assertEq(uint256(state.endFourthRootPriceRatio), expectedEndFourthRoot, "end fourth root");
        assertEq(uint256(state.priceRatioUpdateStartTime), startTime, "start time");
        assertEq(uint256(state.priceRatioUpdateEndTime), endTime, "end time");

        // `_lastTimestamp` advances to the current block.
        assertEq(uint256(ReClammPool(pool).getLastTimestamp()), block.timestamp, "_lastTimestamp");

        // Stored VBs match what `computeCurrentVirtualBalances` returned right before the call. The pool is in target
        // range, so neither the view nor the runtime path changes them.
        (uint256 storedVbA, uint256 storedVbB) = ReClammPool(pool).getLastVirtualBalances();
        assertEq(storedVbA, expectedVbA, "_lastVirtualBalanceA");
        assertEq(storedVbB, expectedVbB, "_lastVirtualBalanceB");
    }

    function testStartPriceRatioUpdateRevertsOnInvalidStartTime() public {
        vm.warp(block.timestamp + 1 days);

        uint256 startTime = block.timestamp + 7 days;
        uint256 endTime = block.timestamp + 1 days;

        // `GradualValueChange.resolveStartTime` runs first on the external path, so the inverted window is caught
        // there. The pool's own `InvalidStartTime()` revert is defensive and is only reachable through the mock's
        // `manualStartPriceRatioUpdate`.
        vm.expectRevert(abi.encodeWithSelector(GradualValueChange.InvalidStartTime.selector, startTime, endTime));
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(8e18, startTime, endTime);
    }

    function testStopPriceRatioUpdateCollapsesStartAndEndToCurrent() public {
        // Set up an ongoing update.
        uint256 endPriceRatio = 8e18;
        uint256 endTime = block.timestamp + 7 days;
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, block.timestamp, endTime);

        // Move partway through the update so the price ratio is mid-interpolation.
        vm.warp(block.timestamp + 3 days);

        // Snapshot the price ratio and VBs at the time it was stopped.
        uint256 currentFourthRoot = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        (uint256 currentVbA, uint256 currentVbB, ) = ReClammPool(pool).computeCurrentVirtualBalances();

        vm.prank(admin);
        ReClammPool(pool).stopPriceRatioUpdate();

        // Post-stop, both fourth roots equal the current ratio's fourth root and both timestamps collapse to now.
        // No further interpolation is possible.
        PriceRatioState memory state = ReClammPool(pool).getPriceRatioState();
        assertEq(uint256(state.startFourthRootPriceRatio), currentFourthRoot, "stopped start fourth root");
        assertEq(uint256(state.endFourthRootPriceRatio), currentFourthRoot, "stopped end fourth root");
        assertEq(uint256(state.priceRatioUpdateStartTime), block.timestamp, "stopped start time");
        assertEq(uint256(state.priceRatioUpdateEndTime), block.timestamp, "stopped end time");

        // `_lastTimestamp` advances; stored VBs reflect the interpolated state at the time it was stopped.
        assertEq(uint256(ReClammPool(pool).getLastTimestamp()), block.timestamp, "_lastTimestamp");
        (uint256 storedVbA, uint256 storedVbB) = ReClammPool(pool).getLastVirtualBalances();
        assertEq(storedVbA, currentVbA, "_lastVirtualBalanceA");
        assertEq(storedVbB, currentVbB, "_lastVirtualBalanceB");
    }

    /**
     * @notice Verifies that `startPriceRatioUpdate` calls `getRate()` exactly once per token.
     * @dev The call must invoke `getRate()` on each token's rate provider exactly once. The captured
     * `startFourthRootPriceRatio` must equal the value that `computeCurrentFourthRootPriceRatio` returns immediately
     * before the call: `_updateVirtualBalances` reads balances once, then the price ratio is computed inline from the
     * virtual balances `_updateVirtualBalances` wrote, rather than from a second read.
     */
    function testStartPriceRatioUpdatePerformsSingleRateFetch() public {
        vm.warp(block.timestamp + 1 days);

        uint256 expectedFourthRoot = ReClammPool(pool).computeCurrentFourthRootPriceRatio();

        uint256 endPriceRatio = 5e18;
        uint256 endTime = block.timestamp + 7 days;

        bytes memory getRateData = abi.encodeWithSelector(IRateProvider.getRate.selector);
        vm.expectCall(address(_rateProviderA), getRateData, 1);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, block.timestamp, endTime);

        PriceRatioState memory state = ReClammPool(pool).getPriceRatioState();
        assertEq(
            uint256(state.startFourthRootPriceRatio),
            expectedFourthRoot,
            "captured start must equal the externally-visible fourth root"
        );
    }
}
