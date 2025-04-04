// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";

contract ReClammPoolVirtualBalancesTest is BaseReClammTest {
    using FixedPoint for uint256;
    using ArrayHelpers for *;

    uint256 private constant _PRICE_RATIO = 2e18; // Max price is 2x min price.
    uint256 private constant _INITIAL_BALANCE_A = 1_000_000e18;
    uint256 private constant _INITIAL_BALANCE_B = 100_000e18;

    function setUp() public virtual override {
        setPriceRatio(_PRICE_RATIO);
        setInitialBalances(_INITIAL_BALANCE_A, _INITIAL_BALANCE_B);
        setPriceShiftDailyRate(0);
        super.setUp();
    }

    function testInitialParams() public view {
        uint256[] memory virtualBalances = _calculateVirtualBalances();

        (uint256[] memory curentVirtualBalances, ) = ReClammPool(pool).getCurrentVirtualBalances();

        assertEq(
            ReClammPool(pool).getCurrentFourthRootPriceRatio(),
            fourthRootPriceRatio(),
            "Invalid fourthRootPriceRatio"
        );
        assertEq(curentVirtualBalances[0], virtualBalances[0], "Invalid virtual A balance");
        assertEq(curentVirtualBalances[1], virtualBalances[1], "Invalid virtual B balance");
    }

    function testWithDifferentInitialBalances__Fuzz(int256 diffCoefficient) public {
        // This test verifies the virtual balances of two pools, where the real balances
        // differ by a certain coefficient while maintaining the balance ratio.

        diffCoefficient = bound(diffCoefficient, -100, 100);
        if (diffCoefficient >= -1 && diffCoefficient <= 1) {
            diffCoefficient = 2;
        }

        uint256[] memory newInitialBalances = new uint256[](2);
        if (diffCoefficient > 0) {
            newInitialBalances[0] = _INITIAL_BALANCE_A * uint256(diffCoefficient);
            newInitialBalances[1] = _INITIAL_BALANCE_B * uint256(diffCoefficient);
        } else {
            newInitialBalances[0] = _INITIAL_BALANCE_A / uint256(-diffCoefficient);
            newInitialBalances[1] = _INITIAL_BALANCE_B / uint256(-diffCoefficient);
        }

        setInitialBalances(newInitialBalances[0], newInitialBalances[1]);
        (address firstPool, address secondPool) = _createNewPool();

        assertEq(
            ReClammPool(firstPool).getCurrentFourthRootPriceRatio(),
            fourthRootPriceRatio(),
            "Invalid fourthRootPriceRatio for firstPool"
        );
        assertEq(
            ReClammPool(secondPool).getCurrentFourthRootPriceRatio(),
            fourthRootPriceRatio(),
            "Invalid fourthRootPriceRatio for newPool"
        );

        (uint256[] memory curentFirstPoolVirtualBalances, ) = ReClammPool(firstPool).getCurrentVirtualBalances();
        (uint256[] memory curentNewPoolVirtualBalances, ) = ReClammPool(secondPool).getCurrentVirtualBalances();

        if (diffCoefficient > 0) {
            assertGt(
                curentNewPoolVirtualBalances[0],
                curentFirstPoolVirtualBalances[0],
                "Virtual A balance should be greater for newPool"
            );
            assertGt(
                curentNewPoolVirtualBalances[1],
                curentFirstPoolVirtualBalances[1],
                "Virtual B balance should be greater for newPool"
            );
        } else {
            assertLt(
                curentNewPoolVirtualBalances[0],
                curentFirstPoolVirtualBalances[0],
                "Virtual A balance should be less for newPool"
            );
            assertLt(
                curentNewPoolVirtualBalances[1],
                curentFirstPoolVirtualBalances[1],
                "Virtual B balance should be less for newPool"
            );
        }
    }

    function testWithDifferentPriceRatio__Fuzz(uint96 endFourthRootPriceRatio) public {
        endFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, 1.001e18, 1_000_000e18)); // Price range cannot be lower than 1.

        uint96 initialFourthRootPriceRatio = fourthRootPriceRatio();
        setFourthRootPriceRatio(endFourthRootPriceRatio);
        (address firstPool, address secondPool) = _createNewPool();

        (uint256[] memory curentFirstPoolVirtualBalances, ) = ReClammPool(firstPool).getCurrentVirtualBalances();
        (uint256[] memory curentNewPoolVirtualBalances, ) = ReClammPool(secondPool).getCurrentVirtualBalances();

        if (endFourthRootPriceRatio > initialFourthRootPriceRatio) {
            assertLt(
                curentNewPoolVirtualBalances[0],
                curentFirstPoolVirtualBalances[0],
                "Virtual A balance should be less for newPool"
            );
            assertLt(
                curentNewPoolVirtualBalances[1],
                curentFirstPoolVirtualBalances[1],
                "Virtual B balance should be less for newPool"
            );
        } else {
            assertGe(
                curentNewPoolVirtualBalances[0],
                curentFirstPoolVirtualBalances[0],
                "Virtual A balance should be greater for newPool"
            );
            assertGe(
                curentNewPoolVirtualBalances[1],
                curentFirstPoolVirtualBalances[1],
                "Virtual B balance should be greater for newPool"
            );
        }
    }

    function testChangingDifferentPriceRatio__Fuzz(uint96 endFourthRootPriceRatio) public {
        endFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, 1.1e18, 10e18));

        uint256 initialFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();

        uint32 duration = 2 hours;

        (uint256[] memory poolVirtualBalancesBefore, ) = ReClammPool(pool).getCurrentVirtualBalances();

        uint32 currentTimestamp = uint32(block.timestamp);

        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(endFourthRootPriceRatio, currentTimestamp, currentTimestamp + duration);
        skip(duration);

        (uint256[] memory poolVirtualBalancesAfter, ) = ReClammPool(pool).getCurrentVirtualBalances();

        if (endFourthRootPriceRatio > initialFourthRootPriceRatio) {
            assertLt(
                poolVirtualBalancesAfter[0],
                poolVirtualBalancesBefore[0],
                "Virtual A balance after should be lower than before"
            );
            assertLt(
                poolVirtualBalancesAfter[1],
                poolVirtualBalancesBefore[1],
                "Virtual B balance after should be lower than before"
            );
        } else {
            assertGe(
                poolVirtualBalancesAfter[0],
                poolVirtualBalancesBefore[0],
                "Virtual A balance after should be greater than before"
            );
            assertGe(
                poolVirtualBalancesAfter[1],
                poolVirtualBalancesBefore[1],
                "Virtual B balance after should be greater than before"
            );
        }
    }

    function testSwapExactIn__Fuzz(uint256 exactAmountIn) public {
        exactAmountIn = bound(exactAmountIn, 1e6, _INITIAL_BALANCE_A);

        (uint256[] memory oldVirtualBalances, ) = ReClammPool(pool).getCurrentVirtualBalances();
        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, exactAmountIn, 1, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        (uint256[] memory newVirtualBalances, ) = ReClammPool(pool).getCurrentVirtualBalances();
        assertEq(newVirtualBalances[0], oldVirtualBalances[0], "Virtual A balances do not match");
        assertEq(newVirtualBalances[1], oldVirtualBalances[1], "Virtual B balances do not match");
    }

    function testSwapExactOut__Fuzz(uint256 exactAmountOut) public {
        exactAmountOut = bound(exactAmountOut, 1e6, _INITIAL_BALANCE_B - _MIN_TOKEN_BALANCE - 1);

        uint256[] memory virtualBalances = _calculateVirtualBalances();
        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, exactAmountOut, UINT256_MAX, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        (uint256[] memory currentVirtualBalances, ) = ReClammPool(pool).getCurrentVirtualBalances();
        assertEq(currentVirtualBalances[0], virtualBalances[0], "Virtual A balances don't equal");
        assertEq(currentVirtualBalances[1], virtualBalances[1], "Virtual B balances don't equal");
    }

    function testAddLiquidity__Fuzz(uint256 exactBptAmountOut) public {
        exactBptAmountOut = bound(exactBptAmountOut, 1e18, 10_000e18);

        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.addLiquidityProportional(
            pool,
            [MAX_UINT128, MAX_UINT128].toMemoryArray(),
            exactBptAmountOut,
            false,
            new bytes(0)
        );

        uint256 invariantAfter = _getCurrentInvariant();

        assertGt(invariantAfter, invariantBefore, "Invariant should increase");

        // TODO: add check for virtual balances
    }

    function testRemoveLiquidity__Fuzz(uint256 exactBptAmountIn) public {
        exactBptAmountIn = bound(exactBptAmountIn, 1e18, 10_000e18);

        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(1), 1].toMemoryArray(),
            false,
            new bytes(0)
        );

        uint256 invariantAfter = _getCurrentInvariant();
        assertLt(invariantAfter, invariantBefore, "Invariant should decrease");

        // TODO: add check for virtual balances
    }

    function _getCurrentInvariant() internal view returns (uint256) {
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);
        return ReClammPool(pool).computeInvariant(balances, Rounding.ROUND_DOWN);
    }

    function _calculateVirtualBalances() internal view returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](2);

        uint256 fourthRootPriceRatioMinusOne = fourthRootPriceRatio() - FixedPoint.ONE;
        virtualBalances[0] = _INITIAL_BALANCE_A.divDown(fourthRootPriceRatioMinusOne);
        virtualBalances[1] = _INITIAL_BALANCE_B.divDown(fourthRootPriceRatioMinusOne);
    }

    function _createNewPool() internal returns (address initalPool, address newPool) {
        initalPool = pool;
        (pool, poolArguments) = createPool();
        approveForPool(IERC20(pool));
        initPool();
        newPool = pool;
    }
}
