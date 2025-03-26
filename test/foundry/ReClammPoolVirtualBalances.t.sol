// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { GyroPoolMath } from "@balancer-labs/v3-pool-gyro/contracts/lib/GyroPoolMath.sol";
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

    uint256 private constant _PRICE_RANGE = 2e18; // Max price is 2x min price.
    uint256 private constant _INITIAL_BALANCE_A = 1_000_000e18;
    uint256 private constant _INITIAL_BALANCE_B = 100_000e18;

    function setUp() public virtual override {
        setPriceRange(_PRICE_RANGE);
        setInitialBalances(_INITIAL_BALANCE_A, _INITIAL_BALANCE_B);
        setIncreaseDayRate(0);
        super.setUp();
    }

    function testInitialParams() public view {
        uint256[] memory virtualBalances = _calculateVirtualBalances();

        uint256[] memory curentVirtualBalances = ReClammPool(pool).getLastVirtualBalances();

        assertEq(ReClammPool(pool).getCurrentSqrtPriceRatio(), sqrtPriceRatio(), "Invalid sqrtPriceRatio");
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
            ReClammPool(firstPool).getCurrentSqrtPriceRatio(),
            sqrtPriceRatio(),
            "Invalid sqrtPriceRatio for firstPool"
        );
        assertEq(
            ReClammPool(secondPool).getCurrentSqrtPriceRatio(),
            sqrtPriceRatio(),
            "Invalid sqrtPriceRatio for newPool"
        );

        uint256[] memory curentFirstPoolVirtualBalances = ReClammPool(firstPool).getLastVirtualBalances();
        uint256[] memory curentNewPoolVirtualBalances = ReClammPool(secondPool).getLastVirtualBalances();

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

    function testWithDifferentPriceRange__Fuzz(uint96 newSqrtPriceRatio) public {
        newSqrtPriceRatio = SafeCast.toUint96(bound(newSqrtPriceRatio, 1.001e18, 1_000_000e18)); // Price range cannot be lower than 1.

        uint96 initialSqrtPriceRatio = sqrtPriceRatio();
        setSqrtPriceRatio(newSqrtPriceRatio);
        (address firstPool, address secondPool) = _createNewPool();

        uint256[] memory curentFirstPoolVirtualBalances = ReClammPool(firstPool).getLastVirtualBalances();
        uint256[] memory curentNewPoolVirtualBalances = ReClammPool(secondPool).getLastVirtualBalances();

        if (newSqrtPriceRatio > initialSqrtPriceRatio) {
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

    // TODO: Fixed in PR #24 (https://github.com/balancer/reclamm/pull/24)
    // function testChangingDifferentPriceRange__Fuzz(uint96 newSqrtPriceRange) public {
    //     newSqrtPriceRange = SafeCast.toUint96(bound(newSqrtPriceRange, 1.1e18, 10e18));

    //     uint96 initialSqrtPriceRange = sqrtPriceRatio();

    //     uint32 duration = 2 hours;

    //     uint256[] memory poolVirtualBalancesBefore = ReClammPool(pool).getLastVirtualBalances();

    //     uint32 currentTimestamp = uint32(block.timestamp);

    //     vm.prank(admin);
    //     ReClammPool(pool).setSqrtPriceRatio(newSqrtPriceRange, currentTimestamp, currentTimestamp + duration);
    //     skip(duration);

    //     uint256[] memory poolVirtualBalancesAfter = ReClammPool(pool).getLastVirtualBalances();

    //     if (newSqrtPriceRange > initialSqrtPriceRange) {
    //         assertLt(
    //             poolVirtualBalancesAfter[0],
    //             poolVirtualBalancesBefore[0],
    //             "Virtual A balance after should be less than before"
    //         );
    //         assertLt(
    //             poolVirtualBalancesAfter[1],
    //             poolVirtualBalancesBefore[1],
    //             "Virtual B balance after should be less than before"
    //         );
    //     } else {
    //         assertGe(
    //             poolVirtualBalancesAfter[0],
    //             poolVirtualBalancesBefore[0],
    //             "Virtual A balance after should be greater than before"
    //         );
    //         assertGe(
    //             poolVirtualBalancesAfter[1],
    //             poolVirtualBalancesBefore[1],
    //             "Virtual B balance after should be greater than before"
    //         );
    //     }
    // }

    function testSwapExactIn__Fuzz(uint256 exactAmountIn) public {
        exactAmountIn = bound(exactAmountIn, 1e6, _INITIAL_BALANCE_A);

        uint256[] memory oldVirtualBalances = ReClammPool(pool).getLastVirtualBalances();
        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, exactAmountIn, 1, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        uint256[] memory newVirtualBalances = ReClammPool(pool).getLastVirtualBalances();
        assertEq(newVirtualBalances[0], oldVirtualBalances[0], "Virtual A balances do not match");
        assertEq(newVirtualBalances[1], oldVirtualBalances[1], "Virtual B balances do not match");
    }

    function testSwapExactOut__Fuzz(uint256 exactAmountOut) public {
        exactAmountOut = bound(exactAmountOut, 1e6, _INITIAL_BALANCE_B);

        uint256[] memory virtualBalances = _calculateVirtualBalances();
        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, exactAmountOut, UINT256_MAX, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        uint256[] memory currentVirtualBalances = ReClammPool(pool).getLastVirtualBalances();
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

        uint256 sqrtPriceRatioMinusOne = sqrtPriceRatio() - FixedPoint.ONE;
        virtualBalances[0] = _INITIAL_BALANCE_A.divDown(sqrtPriceRatioMinusOne);
        virtualBalances[1] = _INITIAL_BALANCE_B.divDown(sqrtPriceRatioMinusOne);
    }

    function _createNewPool() internal returns (address initalPool, address newPool) {
        initalPool = pool;
        (pool, poolArguments) = createPool();
        approveForPool(IERC20(pool));
        initPool();
        newPool = pool;
    }
}
