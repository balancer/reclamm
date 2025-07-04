// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";

import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract ReClammPoolVirtualBalancesTest is BaseReClammTest {
    using FixedPoint for *;
    using ArrayHelpers for *;
    using SafeCast for *;
    using Math for *;

    uint256 private constant _INITIAL_PARAMS_ERROR = 0.0001e16; // 0.001%
    uint256 private constant a = 0;
    uint256 private constant b = 1;

    ReClammMathMock mathMock = new ReClammMathMock();

    function setUp() public virtual override {
        setDailyPriceShiftExponent(0);
        super.setUp();
    }

    function testInitialParams() public view {
        (
            uint256[] memory theoreticalBalances,
            uint256[] memory theoreticalVirtualBalances,
            uint256 theoreticalPriceRatio
        ) = mathMock.computeTheoreticalPriceRatioAndBalances(
                _DEFAULT_MIN_PRICE,
                _DEFAULT_MAX_PRICE,
                _DEFAULT_TARGET_PRICE
            );

        uint256 theoreticalFourthRootPriceRatio = ReClammMath.fourthRootScaled18(theoreticalPriceRatio);
        uint256 balanceRatio = _initialBalances[0].divDown(theoreticalBalances[0]);

        // Error tolerance of 1 million wei (price ratio is computed using the pool balances and may have a small error).
        assertApproxEqAbs(
            _initialFourthRootPriceRatio,
            theoreticalFourthRootPriceRatio,
            1e6,
            "Invalid fourthRootPriceRatio"
        );

        // Don't need to check balances of token[0], since the balance ratio was calculated based on it.
        assertApproxEqRel(
            _initialBalances[1],
            theoreticalBalances[1].mulDown(balanceRatio),
            _INITIAL_PARAMS_ERROR,
            "Invalid balance B"
        );

        assertApproxEqRel(
            _initialVirtualBalances[0],
            theoreticalVirtualBalances[0].mulDown(balanceRatio),
            _INITIAL_PARAMS_ERROR,
            "Invalid virtual A balance"
        );
        assertApproxEqRel(
            _initialVirtualBalances[1],
            theoreticalVirtualBalances[1].mulDown(balanceRatio),
            _INITIAL_PARAMS_ERROR,
            "Invalid virtual B balance"
        );
    }

    function testInitializationWithPrices__Fuzz(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint256 newTargetPrice
    ) public {
        newMinPrice = bound(newMinPrice, _MIN_PRICE, _MAX_PRICE.divDown(_MIN_PRICE_RATIO));
        newMaxPrice = bound(newMaxPrice, newMinPrice.mulUp(_MIN_PRICE_RATIO), _MAX_PRICE);
        newTargetPrice = bound(
            newTargetPrice,
            newMinPrice + newMinPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2),
            newMaxPrice - newMinPrice.mulDown((_MIN_PRICE_RATIO - FixedPoint.ONE) / 2)
        );

        // Assume the pool is in range, else the initialization will revert.
        _assumePoolInRange(newMinPrice, newMaxPrice, newTargetPrice);

        setInitializationPrices(newMinPrice, newMaxPrice, newTargetPrice);
        _createNewPool();

        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);
        (uint256[] memory virtualBalances, ) = _computeCurrentVirtualBalances(pool);

        uint256 currentPrice = (balances[b] + virtualBalances[b]).divDown(balances[a] + virtualBalances[a]);

        assertApproxEqRel(currentPrice, newTargetPrice, _INITIAL_PARAMS_ERROR, "Current price does not match");

        uint256 balanceTokenAEdge = (virtualBalances[b] - virtualBalances[a].mulDown(newMinPrice)).divDown(newMinPrice);
        uint256 invariantTokenAEdge = ReClammPool(pool).computeInvariant(
            [balanceTokenAEdge, 0].toMemoryArray(),
            Rounding.ROUND_DOWN
        );

        uint256 balanceTokenBEdge = virtualBalances[a].mulDown(newMaxPrice) - virtualBalances[b];
        uint256 invariantTokenBEdge = ReClammPool(pool).computeInvariant(
            [0, balanceTokenBEdge].toMemoryArray(),
            Rounding.ROUND_DOWN
        );

        uint256 newInvariant = _getCurrentInvariant();

        assertApproxEqRel(
            invariantTokenAEdge,
            invariantTokenBEdge,
            _INITIAL_PARAMS_ERROR,
            "Invariant at the edges should be equal"
        );
        assertApproxEqRel(invariantTokenAEdge, newInvariant, _INITIAL_PARAMS_ERROR, "Invariant should be equal");
    }

    function testChangingDifferentPriceRatio__Fuzz(uint96 endFourthRootPriceRatio) public {
        endFourthRootPriceRatio = SafeCast.toUint96(bound(endFourthRootPriceRatio, 1.1e18, 2e18));
        uint256 initialFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();

        _assumeFourthRootPriceRatioDeltaAboveMin(initialFourthRootPriceRatio, endFourthRootPriceRatio);

        uint32 duration = 5 days;

        (uint256[] memory poolVirtualBalancesBefore, ) = _computeCurrentVirtualBalances(pool);

        uint32 currentTimestamp = uint32(block.timestamp);

        uint256 endPriceRatio = endFourthRootPriceRatio.mulDown(endFourthRootPriceRatio);
        endPriceRatio = endPriceRatio.mulDown(endPriceRatio);

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, currentTimestamp, currentTimestamp + duration);
        skip(duration);

        (uint256[] memory poolVirtualBalancesAfter, ) = _computeCurrentVirtualBalances(pool);

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
        exactAmountIn = bound(exactAmountIn, 1e6, Math.min(_initialBalances[daiIdx], _initialBalances[usdcIdx]));

        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, exactAmountIn, 1, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);
        assertEq(currentVirtualBalances[daiIdx], _initialVirtualBalances[daiIdx], "DAI Virtual balances do not match");
        assertEq(
            currentVirtualBalances[usdcIdx],
            _initialVirtualBalances[usdcIdx],
            "USDC Virtual balances do not match"
        );
    }

    function testSwapExactOut__Fuzz(uint256 exactAmountOut) public {
        exactAmountOut = bound(exactAmountOut, 1e6, _initialBalances[usdcIdx] - _MIN_TOKEN_BALANCE - 1);

        uint256 invariantBefore = _getCurrentInvariant();

        vm.prank(alice);
        router.swapSingleTokenExactOut(pool, dai, usdc, exactAmountOut, UINT256_MAX, UINT256_MAX, false, new bytes(0));

        uint256 invariantAfter = _getCurrentInvariant();
        assertLe(invariantBefore, invariantAfter, "Invariant should not decrease");

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);
        assertEq(currentVirtualBalances[daiIdx], _initialVirtualBalances[daiIdx], "DAI Virtual balances do not match");
        assertEq(
            currentVirtualBalances[usdcIdx],
            _initialVirtualBalances[usdcIdx],
            "USDC Virtual balances do not match"
        );
    }

    function testAddLiquidityProportional__Fuzz(uint256 exactBptAmountOut) public {
        exactBptAmountOut = bound(exactBptAmountOut, 1e6, 10_000e18);

        uint256 currentTotalSupply = ReClammPool(pool).totalSupply();

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
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);
        (uint256[] memory virtualBalancesAfter, ) = _computeCurrentVirtualBalances(pool);

        assertGt(invariantAfter, invariantBefore, "Invariant should increase");

        assertApproxEqRel(
            balancesAfter[daiIdx],
            _initialBalances[daiIdx].mulDown(FixedPoint.ONE + exactBptAmountOut.divDown(currentTotalSupply)),
            _INITIAL_PARAMS_ERROR,
            "DAI balances do not match"
        );
        assertApproxEqRel(
            balancesAfter[usdcIdx],
            _initialBalances[usdcIdx].mulDown(FixedPoint.ONE + exactBptAmountOut.divDown(currentTotalSupply)),
            _INITIAL_PARAMS_ERROR,
            "USDC balances do not match"
        );

        assertApproxEqRel(
            virtualBalancesAfter[daiIdx],
            _initialVirtualBalances[daiIdx].mulDown(FixedPoint.ONE + exactBptAmountOut.divDown(currentTotalSupply)),
            _INITIAL_PARAMS_ERROR,
            "DAI virtual balances do not match"
        );
        assertApproxEqRel(
            virtualBalancesAfter[usdcIdx],
            _initialVirtualBalances[usdcIdx].mulDown(FixedPoint.ONE + exactBptAmountOut.divDown(currentTotalSupply)),
            _INITIAL_PARAMS_ERROR,
            "USDC virtual balances do not match"
        );
    }

    function testRemoveLiquidity__Fuzz(uint256 exactBptAmountIn) public {
        exactBptAmountIn = bound(exactBptAmountIn, 1e8, ReClammPool(pool).balanceOf(lp));

        uint256 currentTotalSupply = ReClammPool(pool).totalSupply();

        uint256[] memory virtualBalances = new uint256[](2);
        {
            (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = ReClammPool(pool)
                .computeCurrentVirtualBalances();
            virtualBalances[daiIdx] = daiIdx < usdcIdx ? currentVirtualBalanceA : currentVirtualBalanceB;
            virtualBalances[usdcIdx] = daiIdx < usdcIdx ? currentVirtualBalanceB : currentVirtualBalanceA;
        }

        uint256 invariantBefore = _getCurrentInvariant();
        (, , uint256[] memory balancesBefore, ) = vault.getPoolTokenInfo(pool);

        vm.prank(lp);
        router.removeLiquidityProportional(
            pool,
            exactBptAmountIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            new bytes(0)
        );

        uint256 invariantAfter = _getCurrentInvariant();
        (, , uint256[] memory balancesAfter, ) = vault.getPoolTokenInfo(pool);

        uint256[] memory lastVirtualBalances = new uint256[](2);
        {
            (uint256 lastVirtualBalanceA, uint256 lastVirtualBalanceB) = ReClammPool(pool).getLastVirtualBalances();
            lastVirtualBalances[daiIdx] = daiIdx < usdcIdx ? lastVirtualBalanceA : lastVirtualBalanceB;
            lastVirtualBalances[usdcIdx] = daiIdx < usdcIdx ? lastVirtualBalanceB : lastVirtualBalanceA;
        }

        assertLt(invariantAfter, invariantBefore, "Invariant should decrease");

        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[daiIdx] = (balancesBefore[daiIdx] * exactBptAmountIn) / currentTotalSupply;
        amountsOut[usdcIdx] = (balancesBefore[usdcIdx] * exactBptAmountIn) / currentTotalSupply;

        assertEq(balancesAfter[daiIdx], balancesBefore[daiIdx] - amountsOut[daiIdx], "DAI balances do not match");
        assertEq(balancesAfter[usdcIdx], balancesBefore[usdcIdx] - amountsOut[usdcIdx], "USDC balances do not match");

        assertEq(
            lastVirtualBalances[daiIdx],
            (virtualBalances[daiIdx] * (currentTotalSupply - exactBptAmountIn)) / currentTotalSupply,
            "DAI virtual balances do not match"
        );
        assertEq(
            lastVirtualBalances[usdcIdx],
            (virtualBalances[usdcIdx] * (currentTotalSupply - exactBptAmountIn)) / currentTotalSupply,
            "USDC virtual balances do not match"
        );
    }

    function _getCurrentInvariant() internal view returns (uint256) {
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);
        return ReClammPool(pool).computeInvariant(balances, Rounding.ROUND_DOWN);
    }

    function _createNewPool() internal {
        (pool, poolArguments) = createPool();
        approveForPool(IERC20(pool));
        initPool();
    }

    function _assumePoolInRange(uint256 newMinPrice, uint256 newMaxPrice, uint256 newTargetPrice) internal pure {
        (uint256[] memory balances, uint256 virtualBalanceA, uint256 virtualBalanceB, ) = ReClammMath
            .computeTheoreticalPriceRatioAndBalances(newMinPrice, newMaxPrice, newTargetPrice);

        (uint256 centeredness, ) = ReClammMath.computeCenteredness(balances, virtualBalanceA, virtualBalanceB);
        vm.assume(centeredness > _DEFAULT_CENTEREDNESS_MARGIN);
    }
}
