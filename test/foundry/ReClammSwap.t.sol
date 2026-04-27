// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { a, b } from "../../contracts/lib/ReClammMath.sol";

contract ReClammSwapTest is BaseReClammTest {
    using FixedPoint for *;
    using ArrayHelpers for *;

    ReClammMathMock mathMock = new ReClammMathMock();

    function testOutOfRangeSwapExactIn__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactIn__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 2e18);

        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);

        uint256 amountUsdcIn = mathMock.computeInGivenOut(
            balancesScaled18,
            currentVirtualBalances,
            usdcIdx,
            daiIdx,
            (balancesScaled18[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, usdc, dai, amountUsdcIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangePriceRatioUpdatingSwapExactIn__Fuzz(
        uint256 daiBalance,
        uint256 usdcBalance,
        uint256 newFourthRootPriceRatio
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 1.6e18);
        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 30 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range and price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangeSwapExactIn__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN)
        );

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiIn = mathMock.computeInGivenOut(
            newBalances,
            currentVirtualBalances,
            daiIdx,
            usdcIdx,
            (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2
        );

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangeSwapExactOut__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangePriceRatioUpdatingSwapExactOut__Fuzz(uint256 newFourthRootPriceRatio) public {
        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 2e18);

        uint256 currentPriceRatio = currentFourthRootPriceRatio.mulDown(currentFourthRootPriceRatio);
        currentPriceRatio = currentPriceRatio.mulDown(currentPriceRatio);
        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        if (newPriceRatio > currentPriceRatio) {
            vm.assume(newPriceRatio - currentPriceRatio >= _MIN_PRICE_RATIO_DELTA);
        } else {
            vm.assume(currentPriceRatio - newPriceRatio >= _MIN_PRICE_RATIO_DELTA);
        }

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 5 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        // If the price ratio is updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountDaiOut = (poolInitAmount - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, usdc, dai, amountDaiOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testOutOfRangePriceRatioUpdatingSwapExactOut__Fuzz(
        uint256 daiBalance,
        uint256 usdcBalance,
        uint256 newFourthRootPriceRatio
    ) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        uint256 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        newFourthRootPriceRatio = bound(newFourthRootPriceRatio, 1.1e18, 1.6e18);
        _assumeFourthRootPriceRatioDeltaAboveMin(currentFourthRootPriceRatio, newFourthRootPriceRatio);

        uint256 newPriceRatio = newFourthRootPriceRatio.mulDown(newFourthRootPriceRatio);
        newPriceRatio = newPriceRatio.mulDown(newPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, block.timestamp, block.timestamp + 30 days);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(
                newBalances,
                lastVirtualBalancesBeforeSwap,
                _DEFAULT_CENTEREDNESS_MARGIN
            ) == false
        );

        // If the pool is out of range and prices are updating, the virtual balances should not match.
        _assertVirtualBalancesDoNotMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);

        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function testInRangeSwapExactOut__Fuzz(uint256 daiBalance, uint256 usdcBalance) public {
        // Setting balances to be at least 10 * min token balance, so LP can remove 90% of the liquidity
        // without reverting.
        daiBalance = bound(daiBalance, 10 * _MIN_TOKEN_BALANCE, dai.balanceOf(address(vault)));
        usdcBalance = bound(usdcBalance, 10 * _MIN_TOKEN_BALANCE, usdc.balanceOf(address(vault)));

        // Set the pool balances.
        uint256[] memory newBalances = _setPoolBalances(daiBalance, usdcBalance);

        // Set the last timestamp.
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory lastVirtualBalancesBeforeSwap = _getLastVirtualBalances(pool);
        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.assume(
            mathMock.isPoolWithinTargetRange(newBalances, lastVirtualBalancesBeforeSwap, _DEFAULT_CENTEREDNESS_MARGIN)
        );

        // If the pool is in range, the virtual balances should match.
        _assertVirtualBalancesMatch(lastVirtualBalancesBeforeSwap, currentVirtualBalances);

        uint256 amountUsdcOut = (newBalances[usdcIdx] - _MIN_TOKEN_BALANCE) / 2;

        // Make a swap so that `lastVirtualBalances` is updated to match the current virtual balances.
        // The last timestamp should also be updated to the current block.
        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, amountUsdcOut, MAX_UINT256, MAX_UINT256, false, bytes(""));

        uint256[] memory lastVirtualBalancesAfterSwap = _getLastVirtualBalances(pool);
        _assertVirtualBalancesMatch(lastVirtualBalancesAfterSwap, currentVirtualBalances);
        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp does not match");
    }

    function _assertVirtualBalancesMatch(
        uint256[] memory virtualBalances1,
        uint256[] memory virtualBalances2
    ) internal view {
        assertEq(virtualBalances1[daiIdx], virtualBalances2[daiIdx], "DAI virtual balances do not match");
        assertEq(virtualBalances1[usdcIdx], virtualBalances2[usdcIdx], "USDC virtual balances do not match");
    }

    function _assertVirtualBalancesDoNotMatch(
        uint256[] memory virtualBalances1,
        uint256[] memory virtualBalances2
    ) internal view {
        assertNotEq(virtualBalances1[daiIdx], virtualBalances2[daiIdx], "DAI virtual balances remain unchanged");
        assertNotEq(virtualBalances1[usdcIdx], virtualBalances2[usdcIdx], "USDC virtual balances remain unchanged");
    }
}

/**
 * @notice Regression for the original Cantina report on the long-idle bricked-pool scenario.
 * @dev Reproduces the path that originally bricked the pool: drain one side via a swap, idle for ~12 days
 * so the lazy out-of-range update decays the smaller virtual balance below the historical safe floor (1e9),
 * then make a small swap. Under the old `mulDown(Va, Va)` formulation, the small swap (and any subsequent
 * operation) would panic with division by zero in `computePriceRange`. Under the algebraically rearranged
 * `computePriceRatio` (which avoids `mulDown(Va, Va)` entirely), the swap succeeds and the pool stays
 * usable even with one virtual balance well below 1e9.
 *
 * The pool init amount is intentionally small so the post-decay virtual balance lands in the historically
 * unsafe range, exercising the math at the small-VB regime that the rearrangement is designed to handle.
 */
contract ReClammLongIdleDrainTest is BaseReClammTest {
    function setUp() public override {
        poolInitAmount = 1e12;
        super.setUp();
    }

    function testLongIdleDrainStaysUsable() public {
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(50e16);

        (, , uint256[] memory balancesBeforeDrain, ) = vault.getPoolTokenInfo(pool);

        // Identify token A (the one we will drain, sorted index 0) and token B (sorted index 1).
        (address tokenA, address tokenB) = daiIdx == 0 ? (address(dai), address(usdc)) : (address(usdc), address(dai));

        // Drain all of token A by swapping token B in.
        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            IERC20(tokenB),
            IERC20(tokenA),
            balancesBeforeDrain[0],
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Long idle period that drives the lazy virtual balance update down toward the historical 1e9 floor.
        vm.warp(block.timestamp + 25 days);

        // First small swap. Under the old math this committed a degraded virtual balance to storage; under
        // the new math the result is well-defined and the swap succeeds.
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, IERC20(tokenB), IERC20(tokenA), 1, 0, MAX_UINT256, false, bytes(""));

        (uint256 vaAfterFirstSwap, uint256 vbAfterFirstSwap) = ReClammPool(pool).getLastVirtualBalances();
        assertLt(vaAfterFirstSwap, 1e9, "Va should have decayed below the historical safe floor");
        assertGt(vaAfterFirstSwap, 0, "Va should be strictly positive");
        assertGt(vbAfterFirstSwap, 0, "Vb should be strictly positive");

        // A short additional idle period.
        vm.warp(block.timestamp + 1 hours);

        // Under the old math, both of the following would panic with division by zero. Under the new math
        // they both succeed.
        ReClammPool(pool).computeCurrentVirtualBalances();

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, IERC20(tokenB), IERC20(tokenA), 1, 0, MAX_UINT256, false, bytes(""));
    }
}

/**
 * @notice Documents the MEV surface around in-range price ratio widening updates.
 * @dev When a price ratio update is active, `computeVirtualBalancesUpdatingPriceRatio` preserves the pool's current
 * centeredness at the new (wider) ratio. Because centeredness is computed from live balances, a swap during the
 * update window changes the centeredness that gets locked in, and the widening amplifies the attacker-chosen
 * imbalance.
 *
 * Whether this is profitable depends on pool depth: the extraction scales with pool size (wider pool = less
 * price impact per unit of imbalance), so deeper pools are more exposed. The tests below confirm the finding
 * is real at sufficient pool depth and document the fee threshold that neutralizes it.
 *
 * Governance should prefer gradual price ratio updates over large instantaneous ones to limit this surface.
 */
contract ReClammPriceRatioWideningRoundTripTest is BaseReClammTest {
    using FixedPoint for *;

    // Use a duration slightly above 2 day so the 2x widening stays just under the maximum allowed daily
    // rate. At exactly 2 day the rate lands right on the boundary and rounding in divUp/powUp can push
    // the computed rate a hair above the max, causing PriceRatioUpdateTooFast.
    uint256 private constant _UPDATE_DURATION = 2 days + 1 minutes;

    function setUp() public override {
        // Match the audit's witness: min/max/target = 1000/4000/2000.
        setInitializationPrices(1000e18, 4000e18, 2000e18);
        // Large pool (~414k A after init at target=2000). The extraction scales with pool depth.
        poolInitAmount = 414_000e18;
        super.setUp();
    }

    /// @dev Reproduces the audit finding. Confirms the round trip is profitable at zero fees with a 2x
    /// widening at the audit's specific parameters, documenting the real extraction magnitude.
    function testWideningRoundTripProfitableAtLargePoolSize() public {
        vault.manualUnsafeSetStaticSwapFeePercentage(pool, 0);

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(pool);
        IERC20 tokenA = tokens[a];
        IERC20 tokenB = tokens[b];

        uint256 attackerABefore = tokenA.balanceOf(alice);

        // 100k A on a ~414k-A pool, matching the audit's witness.
        uint256 swapAmount = 100_000e18;

        vm.prank(alice);
        uint256 amountBReceived = router.swapSingleTokenExactIn(
            pool,
            tokenA,
            tokenB,
            swapAmount,
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        assertTrue(ReClammPool(pool).isPoolWithinTargetRange(), "Pool should still be in range after setup swap");

        skip(1 seconds);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(8e18, block.timestamp, block.timestamp + _UPDATE_DURATION);

        skip(_UPDATE_DURATION);

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, tokenB, tokenA, amountBReceived, 0, MAX_UINT256, false, bytes(""));

        uint256 attackerAAfter = tokenA.balanceOf(alice);

        // At zero fees and large pool depth, the widening extraction is real and profitable.
        assertGt(attackerAAfter, attackerABefore, "Round trip should profit at large pool size with zero fees");

        // The profit should be material. The audit's witness shows ~2.55% of the swap amount.
        uint256 profit = attackerAAfter - attackerABefore;
        uint256 profitBps = (profit * 10000) / swapAmount;
        assertGt(profitBps, 200, "Profit should be at least 2% of swap amount");
    }

    /// @dev Same large-pool scenario, but with a swap fee. Searches for the fee that neutralizes the profit.
    function testWideningRoundTripNeutralizedByFees() public {
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(pool);
        IERC20 tokenA = tokens[a];
        IERC20 tokenB = tokens[b];

        uint256 swapAmount = 100_000e18;

        // Binary search for the minimum fee that makes the round trip unprofitable.
        // The threshold scales with widening magnitude; 2x is the maximum allowed per day.
        uint256 low = 1; // 0.001%
        uint256 high = 3000; // 3%
        uint256 snap;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            uint256 fee = mid * 0.001e16;

            snap = vm.snapshotState();

            vault.manualUnsafeSetStaticSwapFeePercentage(pool, fee);

            uint256 attackerABefore = tokenA.balanceOf(alice);

            vm.prank(alice);
            uint256 amountBReceived = router.swapSingleTokenExactIn(
                pool,
                tokenA,
                tokenB,
                swapAmount,
                0,
                MAX_UINT256,
                false,
                bytes("")
            );

            skip(1 seconds);

            vm.prank(admin);
            ReClammPool(pool).startPriceRatioUpdate(8e18, block.timestamp, block.timestamp + _UPDATE_DURATION);

            skip(_UPDATE_DURATION);

            vm.prank(alice);
            router.swapSingleTokenExactIn(pool, tokenB, tokenA, amountBReceived, 0, MAX_UINT256, false, bytes(""));

            bool profitable = tokenA.balanceOf(alice) > attackerABefore;
            vm.revertToState(snap);

            if (profitable) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        uint256 minSafeFee = low * 0.001e16;

        // Confirm the search didn't hit the ceiling.
        assertLt(low, 3000, "Search hit ceiling; widen the range");

        // A 2x widening (the maximum allowed daily rate) requires a swap fee above this threshold
        // to neutralize extraction at large pool depth. Smaller widenings require proportionally less.
        assertLt(minSafeFee, 2e16, "Safe fee for 2x widening should be below 2%");

        // Verify: the search found a real boundary (not already unprofitable at minimum fee).
        assertGt(low, 1, "Minimum fee already unprofitable; boundary check cannot verify");

        // Verify: one step below the found fee is still profitable, confirming the boundary.
        snap = vm.snapshotState();
        vault.manualUnsafeSetStaticSwapFeePercentage(pool, (low - 1) * 0.001e16);

        uint256 aBefore = tokenA.balanceOf(alice);

        vm.prank(alice);
        uint256 bReceived = router.swapSingleTokenExactIn(
            pool,
            tokenA,
            tokenB,
            swapAmount,
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        skip(1 seconds);
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(8e18, block.timestamp, block.timestamp + _UPDATE_DURATION);
        skip(_UPDATE_DURATION);

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, tokenB, tokenA, bReceived, 0, MAX_UINT256, false, bytes(""));

        assertGt(tokenA.balanceOf(alice), aBefore, "One step below safe fee should still be profitable");
        vm.revertToState(snap);
    }
}
