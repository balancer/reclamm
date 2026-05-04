// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { PriceRatioState, ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactoryLib, ReClammPriceParams } from "../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolFactoryMock } from "../../contracts/test/ReClammPoolFactoryMock.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import {
    IReClammPool,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData,
    ReClammPoolParams
} from "../../contracts/interfaces/IReClammPool.sol";

contract ReClammPoolTest is BaseReClammTest {
    using FixedPoint for *;
    using CastingHelpers for *;
    using ArrayHelpers for *;
    using SafeCast for *;

    uint256 private constant _NEW_CENTEREDNESS_MARGIN = 30e16;
    uint256 private constant _INITIAL_AMOUNT = 1000e18;

    // Tokens with decimals introduces some rounding imprecisions, so we need to be more tolerant with the inverse
    // initialization error.
    uint256 private constant _INVERSE_INITIALIZATION_ERROR = 1e12;
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    uint256 private constant _MAX_CENTEREDNESS_MARGIN = 90e16; // 90%

    uint256 private constant _MIN_PRICE_RATIO_UPDATE_DURATION = 1 days;
    uint256 private constant _BALANCE_RATIO_AND_PRICE_TOLERANCE = 0.01e16; // 0.01%

    ReClammMathMock mathMock = new ReClammMathMock();

    function testOnRegisterPoolArgument() public view {
        address wrongPool = address(0x123);
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = true;
        liquidityManagement.enableDonation = false;
        bool result = ReClammPool(pool).onRegister(poolFactory, wrongPool, tokenConfig, liquidityManagement);
        assertFalse(result, "onRegister should return false for wrong pool argument");
    }

    function testOnRegisterTokenConfig() public view {
        TokenConfig[] memory tokenConfig = new TokenConfig[](3);
        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = true;
        liquidityManagement.enableDonation = false;
        bool result = ReClammPool(pool).onRegister(poolFactory, pool, tokenConfig, liquidityManagement);
        assertFalse(result, "onRegister should return false for wrong token config length");
    }

    function testOnRegisterLiquidityManagement() public view {
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = false;
        liquidityManagement.enableDonation = false;
        bool result = ReClammPool(pool).onRegister(poolFactory, pool, tokenConfig, liquidityManagement);
        assertFalse(
            result,
            "onRegister should return false for wrong liquidity management (disableUnbalancedLiquidity)"
        );

        liquidityManagement.disableUnbalancedLiquidity = true;
        liquidityManagement.enableDonation = true;
        result = ReClammPool(pool).onRegister(poolFactory, pool, tokenConfig, liquidityManagement);
        assertFalse(result, "onRegister should return false for wrong liquidity management (enableDonation)");
    }

    function testOnRegisterCorrectArguments() public view {
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = true;
        liquidityManagement.enableDonation = false;
        bool result = ReClammPool(pool).onRegister(poolFactory, pool, tokenConfig, liquidityManagement);
        assertTrue(result, "onRegister should return true for correct arguments");
    }

    function testOnSwapOnlyVault() public {
        PoolSwapParams memory request;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        ReClammPool(pool).onSwap(request);
    }

    function testOnBeforeInitializeOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        ReClammPool(pool).onBeforeInitialize(new uint256[](2), bytes(""));
    }

    function testOnBeforeAddLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        ReClammPool(pool).onBeforeAddLiquidity(
            address(this),
            pool,
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            0,
            new uint256[](2),
            bytes("")
        );
    }

    function testOnBeforeAddLiquidityPoolArgument() public {
        address wrongPool = address(0x123);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IReClammPool.InvalidPoolArgument.selector, wrongPool));
        ReClammPool(pool).onBeforeAddLiquidity(
            address(this),
            wrongPool,
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            0,
            new uint256[](2),
            bytes("")
        );
    }

    function testOnBeforeRemoveLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        ReClammPool(pool).onBeforeRemoveLiquidity(
            address(this),
            pool,
            RemoveLiquidityKind.PROPORTIONAL,
            1,
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );
    }

    function testOnBeforeRemoveLiquidityPoolArgument() public {
        address wrongPool = address(0x123);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IReClammPool.InvalidPoolArgument.selector, wrongPool));
        ReClammPool(pool).onBeforeRemoveLiquidity(
            address(this),
            wrongPool,
            RemoveLiquidityKind.PROPORTIONAL,
            1,
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );
    }

    function testComputeCurrentFourthRootPriceRatio() public view {
        uint256 fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, _initialFourthRootPriceRatio, "Invalid default fourthRootPriceRatio");
    }

    function testGetCenterednessMargin() public {
        uint256 centerednessMargin = ReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, _DEFAULT_CENTEREDNESS_MARGIN, "Invalid default centerednessMargin");

        vm.prank(admin);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);

        centerednessMargin = ReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, _NEW_CENTEREDNESS_MARGIN, "Invalid new centerednessMargin");
    }

    function testGetLastTimestamp() public {
        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(_DEFAULT_CENTEREDNESS_MARGIN / 2);

        uint256 lastTimestampBeforeWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampBeforeWarp, block.timestamp, "Invalid lastTimestamp before warp");

        skip(1 hours);
        uint256 lastTimestampAfterWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampAfterWarp, lastTimestampBeforeWarp, "Invalid lastTimestamp after warp");

        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(_DEFAULT_CENTEREDNESS_MARGIN);

        uint256 lastTimestampAfterSetDailyPriceShiftExponent = ReClammPool(pool).getLastTimestamp();
        assertEq(
            lastTimestampAfterSetDailyPriceShiftExponent,
            block.timestamp,
            "Invalid lastTimestamp after setDailyPriceShiftExponent"
        );
    }

    function testGetDailyPriceShiftBase() public {
        uint256 dailyPriceShiftExponent = 20e16;
        uint256 expectedDailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(dailyPriceShiftExponent);
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(dailyPriceShiftExponent);

        uint256 actualDailyPriceShiftDailyBase = ReClammPool(pool).getDailyPriceShiftBase();
        assertEq(actualDailyPriceShiftDailyBase, expectedDailyPriceShiftBase, "Invalid DailyPriceShiftBase");
    }

    function testGetDailyPriceShiftExponentToBase() public {
        uint256 dailyPriceRateExponent = _DEFAULT_CENTEREDNESS_MARGIN / 2;
        vm.prank(admin);
        uint256 actualDailyPriceShiftExponentReturned = ReClammPool(pool).setDailyPriceShiftExponent(
            dailyPriceRateExponent
        );

        uint256 actualDailyPriceShiftBase = ReClammPool(pool).getDailyPriceShiftBase();
        uint256 actualDailyPriceShiftExponent = ReClammPool(pool).getDailyPriceShiftExponent();
        assertEq(
            FixedPoint.ONE - actualDailyPriceShiftExponent / _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT,
            actualDailyPriceShiftBase,
            "Invalid dailyPriceShiftBase"
        );

        assertApproxEqRel(
            actualDailyPriceShiftExponent,
            dailyPriceRateExponent,
            1e16,
            "Invalid dailyPriceRateExponent"
        );

        assertEq(
            actualDailyPriceShiftExponentReturned,
            actualDailyPriceShiftExponent,
            "Invalid dailyPriceRateExponent returned"
        );
    }

    function testGetPriceRatioState() public {
        PriceRatioState memory priceRatioState = ReClammPool(pool).getPriceRatioState();
        assertApproxEqAbs(
            priceRatioState.startFourthRootPriceRatio,
            _initialFourthRootPriceRatio,
            1e6,
            "Invalid default startFourthRootPriceRatio"
        );
        // Error tolerance of 1m wei (price ratio is computed using the pool balances and may have a small error).
        assertApproxEqAbs(
            priceRatioState.endFourthRootPriceRatio,
            _initialFourthRootPriceRatio,
            1e6,
            "Invalid default endFourthRootPriceRatio"
        );
        assertEq(
            priceRatioState.priceRatioUpdateStartTime,
            block.timestamp,
            "Invalid default priceRatioUpdateStartTime"
        );
        assertEq(priceRatioState.priceRatioUpdateEndTime, block.timestamp, "Invalid default priceRatioUpdateEndTime");

        uint256 oldFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
        uint256 newFourthRootPriceRatio = oldFourthRootPriceRatio.mulDown(90e16);
        uint256 newPriceRatio = _pow4(newFourthRootPriceRatio);
        uint256 newPriceRatioUpdateStartTime = block.timestamp;
        uint256 newPriceRatioUpdateEndTime = block.timestamp + 10 days;

        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(
            newPriceRatio,
            newPriceRatioUpdateStartTime,
            newPriceRatioUpdateEndTime
        );

        priceRatioState = ReClammPool(pool).getPriceRatioState();
        assertEq(
            priceRatioState.startFourthRootPriceRatio,
            oldFourthRootPriceRatio,
            "Invalid new startFourthRootPriceRatio"
        );
        assertApproxEqRel(
            priceRatioState.endFourthRootPriceRatio,
            newFourthRootPriceRatio,
            1,
            "Invalid new endFourthRootPriceRatio"
        );
        assertEq(
            priceRatioState.priceRatioUpdateStartTime,
            newPriceRatioUpdateStartTime,
            "Invalid new priceRatioUpdateStartTime"
        );
        assertEq(
            priceRatioState.priceRatioUpdateEndTime,
            newPriceRatioUpdateEndTime,
            "Invalid new priceRatioUpdateEndTime"
        );
    }

    function testGetReClammPoolDynamicData() public {
        // Modify values using setters
        uint256 newDailyPriceShiftExponent = _DEFAULT_CENTEREDNESS_MARGIN / 2;
        uint256 endPriceRatio = 16e18;
        uint256 endFourthRootPriceRatio = 2e18;
        uint256 newStaticSwapFeePercentage = 5e16;

        PriceRatioState memory state = PriceRatioState({
            startFourthRootPriceRatio: ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96(),
            endFourthRootPriceRatio: endFourthRootPriceRatio.toUint96(),
            priceRatioUpdateStartTime: block.timestamp.toUint32(),
            priceRatioUpdateEndTime: (block.timestamp + 10 days).toUint32()
        });

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.startPrank(admin);
        ReClammPool(pool).startPriceRatioUpdate(
            endPriceRatio,
            state.priceRatioUpdateStartTime,
            state.priceRatioUpdateEndTime
        );
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
        vault.setStaticSwapFeePercentage(pool, newStaticSwapFeePercentage);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours);

        uint256 currentPriceRatio = ReClammPool(pool).computeCurrentPriceRatio();
        uint96 currentFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        // Get initial dynamic data.
        ReClammPoolDynamicData memory data = ReClammPool(pool).getReClammPoolDynamicData();

        // Check balances.
        assertEq(data.balancesLiveScaled18.length, 2, "Invalid number of balances");
        (, , , uint256[] memory balancesLiveScaled18) = vault.getPoolTokenInfo(pool);
        assertEq(data.balancesLiveScaled18[daiIdx], balancesLiveScaled18[daiIdx], "Invalid DAI balance");
        assertEq(data.balancesLiveScaled18[usdcIdx], balancesLiveScaled18[usdcIdx], "Invalid USDC balance");

        // Check token rates.
        assertEq(data.tokenRates.length, 2, "Invalid number of token rates");
        (, uint256[] memory tokenRates) = vault.getPoolTokenRates(pool);
        assertEq(data.tokenRates[daiIdx], tokenRates[daiIdx], "Invalid DAI token rate");
        assertEq(data.tokenRates[usdcIdx], tokenRates[usdcIdx], "Invalid USDC token rate");

        assertEq(data.staticSwapFeePercentage, newStaticSwapFeePercentage, "Invalid static swap fee percentage");
        assertEq(data.totalSupply, ReClammPool(pool).totalSupply(), "Invalid total supply");

        // Check pool specific parameters.
        assertEq(data.lastTimestamp, block.timestamp - 6 hours, "Invalid last timestamp");
        assertEq(data.currentPriceRatio, currentPriceRatio, "Invalid current price ratio");
        assertEq(
            data.currentFourthRootPriceRatio,
            currentFourthRootPriceRatio,
            "Invalid current fourth root price ratio"
        );
        assertEq(
            data.startFourthRootPriceRatio,
            state.startFourthRootPriceRatio,
            "Invalid start fourth root price ratio"
        );
        assertEq(data.endFourthRootPriceRatio, state.endFourthRootPriceRatio, "Invalid end fourth root price ratio");
        assertEq(data.priceRatioUpdateStartTime, state.priceRatioUpdateStartTime, "Invalid start time");
        assertEq(data.priceRatioUpdateEndTime, state.priceRatioUpdateEndTime, "Invalid end time");

        assertEq(data.centerednessMargin, _NEW_CENTEREDNESS_MARGIN, "Invalid centeredness margin");
        assertEq(
            data.dailyPriceShiftBase,
            FixedPoint.ONE - newDailyPriceShiftExponent / 124649,
            "Invalid daily price shift base"
        );
        assertEq(
            data.dailyPriceShiftExponent,
            mathMock.toDailyPriceShiftExponent(data.dailyPriceShiftBase),
            "Invalid daily price shift exponent"
        );
        assertEq(data.lastVirtualBalances.length, 2, "Invalid number of last virtual balances");
        assertEq(data.lastVirtualBalances[daiIdx], currentVirtualBalances[daiIdx], "Invalid DAI last virtual balance");
        assertEq(
            data.lastVirtualBalances[usdcIdx],
            currentVirtualBalances[usdcIdx],
            "Invalid USDC last virtual balance"
        );

        assertEq(data.isPoolInitialized, true, "Pool should remain initialized");
        assertEq(data.isPoolPaused, false, "Pool should remain unpaused");
        assertEq(data.isPoolInRecoveryMode, false, "Pool should remain not in recovery mode");
    }

    function testGetReClammPoolImmutableData() public view {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();
        // Check Base Pool parameters.
        assertEq(data.tokens.length, 2, "Invalid number of tokens");
        assertEq(data.minSwapFeePercentage, _MIN_SWAP_FEE_PERCENTAGE, "Invalid minimum swap fee");
        assertEq(data.maxSwapFeePercentage, _MAX_SWAP_FEE_PERCENTAGE, "Invalid maximum swap fee");

        assertEq(address(data.tokens[daiIdx]), address(dai), "Invalid DAI token");
        assertEq(address(data.tokens[usdcIdx]), address(usdc), "Invalid USDC token");

        // Tokens with 18 decimals do not scale, so the scaling factor is 1.
        assertEq(data.decimalScalingFactors.length, 2, "Invalid number of decimal scaling factors");
        assertEq(data.decimalScalingFactors[daiIdx], 1, "Invalid DAI decimal scaling factor");
        assertEq(data.decimalScalingFactors[usdcIdx], 1, "Invalid USDC decimal scaling factor");

        assertFalse(data.tokenAPriceIncludesRate, "Token A priced with rate");
        assertFalse(data.tokenBPriceIncludesRate, "Token B priced with rate");

        // Check initialization parameters.
        assertEq(data.initialMinPrice, _DEFAULT_MIN_PRICE, "Invalid initial minimum price");
        assertEq(data.initialMaxPrice, _DEFAULT_MAX_PRICE, "Invalid initial maximum price");
        assertEq(data.initialTargetPrice, _DEFAULT_TARGET_PRICE, "Invalid initial target price");
        assertEq(
            data.initialDailyPriceShiftExponent,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            "Invalid initial price shift exponent"
        );
        assertEq(data.initialCenterednessMargin, _DEFAULT_CENTEREDNESS_MARGIN, "Invalid initial centeredness margin");

        // Check operating limit parameters.
        assertEq(data.minPriceRatio, ReClammPoolFactoryLib.MIN_PRICE_RATIO, "Invalid min price ratio");
        assertEq(data.maxPriceRatio, ReClammPoolFactoryLib.MAX_PRICE_RATIO, "Invalid max price ratio");
        assertEq(data.maxCenterednessMargin, _MAX_CENTEREDNESS_MARGIN, "Invalid max centeredness margin");

        // Ensure that the max centeredness margin parameter fits in uint64.
        assertEq(data.maxCenterednessMargin, uint64(data.maxCenterednessMargin), "Max centeredness margin not uint64");
        assertEq(
            data.maxDailyPriceShiftExponent,
            _MAX_DAILY_PRICE_SHIFT_EXPONENT,
            "Invalid max daily price shift exponent"
        );
        uint256 maxUpdateRate = FixedPoint.powUp(2e18, _MAX_DAILY_PRICE_SHIFT_EXPONENT);

        assertEq(data.maxDailyPriceRatioUpdateRate, maxUpdateRate, "Invalid max daily price ratio update rate");
        assertEq(
            data.minPriceRatioUpdateDuration,
            _MIN_PRICE_RATIO_UPDATE_DURATION,
            "Invalid min price ratio update duration"
        );
        assertEq(data.minPriceRatioDelta, _MIN_PRICE_RATIO_DELTA, "Invalid min fourth root price ratio delta");
        assertEq(
            data.balanceRatioAndPriceTolerance,
            _BALANCE_RATIO_AND_PRICE_TOLERANCE,
            "Invalid balance ratio and price tolerance"
        );
    }

    function testSetFourthRootPriceRatioPermissioned() public {
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        vm.prank(alice);
        ReClammPool(pool).startPriceRatioUpdate(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioShortDuration() public {
        uint96 endPriceRatio = 16e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 1 days;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(IReClammPool.PriceRatioUpdateDurationTooShort.selector);
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    function testSetFourthRootPriceRatioSmallDelta() public {
        uint256 delta = _MIN_PRICE_RATIO_DELTA - 1;
        uint96 startPriceRatio = ReClammPool(pool).computeCurrentPriceRatio().toUint96();
        uint96 endPriceRatio = startPriceRatio + delta.toUint96();
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp);
        uint32 duration = 1 days;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioDeltaBelowMin.selector, delta));
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(endPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    function testSetFourthRootPriceRatioTooFast() public {
        uint256 newPriceRatio = 20e18;
        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp + 1 days;

        // The previous approach (calculating the exact point where it would be too fast) no longer works when we're
        // passing in the actual price ratio, since the error in pow >> 1-2 wei delta that would meaningfully check the
        // boundary. And the error is only raised in the external function, so we can't use the mock here. Best we can
        // do is set a large update that would be too fast, and show that the error is triggered.
        vm.expectRevert(IReClammPool.PriceRatioUpdateTooFast.selector);
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    /**
     * @notice Proves that the exponential daily-rate formula allows a 7× price ratio update over 3 days, while
     * the old linear formula would have incorrectly rejected it.
     * @dev Linear rate: (20/2) × (1/7) ≈ 1.428 > 2^(1/2) = 1.414..; would fail.
     * Exponential rate: (20/2)^(1/7) = 10^(1/7) ≈ 1.389 < 1.414; passes.
     */
    function testDailyPriceRatioUpdateRateExponentialVsLinear() public view {
        uint256 maxDailyPriceRatioUpdateRate = IReClammPool(pool)
            .getReClammPoolImmutableData()
            .maxDailyPriceRatioUpdateRate;

        // The old linear formula: (max/min) × (1 day / duration).
        // With startPriceRatio=2e18, endPriceRatio=20e18, duration=7 days this gives 10/7 ≈ 1.428.
        uint256 linearRate = FixedPoint.divUp(20e18 * 1 days, 2e18 * 7 days);
        assertGt(linearRate, maxDailyPriceRatioUpdateRate, "linear rate should exceed the limit");

        // The new exponential formula: (max/min)^(1 day / duration).
        // With startPriceRatio=2e18, endPriceRatio=20e18, duration=7 days this gives 10^(1/7) ≈ 1.389.
        uint256 exponentialRate = ReClammPoolMock(pool).computeDailyPriceRatioUpdateRate(2e18, 20e18, 7 days);
        assertLe(exponentialRate, maxDailyPriceRatioUpdateRate, "exponential rate should be within the limit");

        // 10^(1/7) ≈ 1.38949, tolerance of 1e14 (0.01% precision).
        assertApproxEqAbs(exponentialRate, 1.38949e18, 1e14, "exponential rate should be ~10^(1/7)");
    }

    function testSetPriceRatioTooLow() public {
        uint256 newPriceRatio = ReClammPoolFactoryLib.MIN_PRICE_RATIO - 1;
        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp + 1 days;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioBelowMin.selector, newPriceRatio));
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    function testSetPriceRatioTooHigh() public {
        uint256 newPriceRatio = ReClammPoolFactoryLib.MAX_PRICE_RATIO + 1;
        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp + 1 days;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioAboveMax.selector, newPriceRatio));
        vm.prank(admin);
        ReClammPool(pool).startPriceRatioUpdate(newPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    function testSetFourthRootPriceRatio() public {
        uint96 endPriceRatio = 16e18;
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 10 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            block.timestamp,
            priceRatioUpdateEndTime
        );

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceRatioStateUpdated",
            abi.encode(startFourthRootPriceRatio, endFourthRootPriceRatio, block.timestamp, priceRatioUpdateEndTime)
        );

        vm.prank(admin);
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
        assertEq(actualPriceRatioUpdateStartTime, block.timestamp, "Invalid updated actual price ratio start time");

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        uint96 mathFourthRootPriceRatio = mathMock.computeFourthRootPriceRatio(
            uint32(block.timestamp),
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            actualPriceRatioUpdateStartTime.toUint32(),
            priceRatioUpdateEndTime
        );

        // Allows a 5 wei error, since the current fourth root price ratio of the pool is computed using the pool
        // current balances and virtual balances.
        assertApproxEqAbs(
            fourthRootPriceRatio,
            mathFourthRootPriceRatio,
            5,
            "FourthRootPriceRatio not updated correctly"
        );

        skip(duration / 2 + 1);
        fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        // Allows a 5 wei error, since the current fourth root price ratio of the pool is computed using the pool
        // current balances and virtual balances.
        assertApproxEqAbs(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            5,
            "FourthRootPriceRatio does not match new value"
        );
    }

    /// @dev Trigger a price ratio update while another one is ongoing.
    function testSetFourthRootPriceRatioOverride() public {
        uint96 endPriceRatio = 16e18;
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 10 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        // Events:
        // - Timestamp update
        // - Price ratio state update
        // Virtual balances don't change in this case.
        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            block.timestamp,
            priceRatioUpdateEndTime
        );

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceRatioStateUpdated",
            abi.encode(startFourthRootPriceRatio, endFourthRootPriceRatio, block.timestamp, priceRatioUpdateEndTime)
        );

        vm.prank(admin);
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
        assertEq(actualPriceRatioUpdateStartTime, block.timestamp, "Invalid updated actual price ratio start time");

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        uint96 mathFourthRootPriceRatio = mathMock.computeFourthRootPriceRatio(
            uint32(block.timestamp),
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            actualPriceRatioUpdateStartTime.toUint32(),
            priceRatioUpdateEndTime
        );

        // Allows a 5 wei error, since the current fourth root price ratio of the pool is computed using the pool
        // current balances and virtual balances, and the mathFourthRootPriceRatio is an interpolation.
        assertApproxEqAbs(
            fourthRootPriceRatio,
            mathFourthRootPriceRatio,
            5,
            "FourthRootPriceRatio not updated correctly"
        );

        // While the update is ongoing, we'll trigger a second one.
        // This one will update virtual balances too.
        endPriceRatio = 19.4481e18; // 2.1^4 (below max limit)
        endFourthRootPriceRatio = 2.1e18;
        timeOffset = 1 hours;
        priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        duration = 10 days;
        priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = ReClammPool(pool)
            .computeCurrentVirtualBalances();

        // Events:
        // - Virtual balances update
        // - Timestamp update
        // - Price ratio state update
        vm.expectEmit(pool);
        emit IReClammPool.VirtualBalancesUpdated(currentVirtualBalanceA, currentVirtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "VirtualBalancesUpdated",
            abi.encode(currentVirtualBalanceA, currentVirtualBalanceB)
        );

        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            block.timestamp,
            priceRatioUpdateEndTime
        );

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceRatioStateUpdated",
            abi.encode(startFourthRootPriceRatio, endFourthRootPriceRatio, block.timestamp, priceRatioUpdateEndTime)
        );

        vm.prank(admin);
        actualPriceRatioUpdateStartTime = ReClammPool(pool).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        vm.warp(priceRatioUpdateEndTime + 1);
        fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        // Allows a 15 wei error, since the current fourth root price ratio of the pool is computed using the pool
        // current balances and virtual balances.
        assertApproxEqAbs(
            fourthRootPriceRatio,
            endFourthRootPriceRatio,
            15,
            "FourthRootPriceRatio does not match new value"
        );
    }

    function testStopPriceRatioUpdatePermissioned() public {
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        vm.prank(alice);
        ReClammPool(pool).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdatePoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        vm.prank(admin);
        ReClammPool(pool).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdatePriceRatioNotUpdating() public {
        skip(1 hours);
        vm.expectRevert(IReClammPool.PriceRatioNotUpdating.selector);
        vm.prank(admin);
        ReClammPool(pool).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdate() public {
        uint96 endPriceRatio = 16e18;
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 10 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        vm.prank(admin);
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        uint96 mathFourthRootPriceRatio = mathMock.computeFourthRootPriceRatio(
            uint32(block.timestamp),
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            actualPriceRatioUpdateStartTime.toUint32(),
            priceRatioUpdateEndTime
        );

        // Allows a 5 wei error, since the current fourth root price ratio of the pool is computed using the pool
        // current balances and virtual balances, and the mathFourthRootPriceRatio is an interpolation.
        assertApproxEqAbs(
            fourthRootPriceRatio,
            mathFourthRootPriceRatio,
            5,
            "FourthRootPriceRatio not updated correctly"
        );

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = ReClammPool(pool)
            .computeCurrentVirtualBalances();

        // Events:
        // - Virtual balances update
        // - Timestamp update
        // - Price ratio state update
        vm.expectEmit(pool);
        emit IReClammPool.VirtualBalancesUpdated(currentVirtualBalanceA, currentVirtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "VirtualBalancesUpdated",
            abi.encode(currentVirtualBalanceA, currentVirtualBalanceB)
        );

        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        // Price ratio update event with current value and timestamp.
        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            fourthRootPriceRatio,
            fourthRootPriceRatio,
            block.timestamp,
            block.timestamp
        );

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceRatioStateUpdated",
            abi.encode(fourthRootPriceRatio, fourthRootPriceRatio, block.timestamp, block.timestamp)
        );

        vm.prank(admin);
        ReClammPool(pool).stopPriceRatioUpdate();

        uint96 fourthRootPriceRatioAfterStop = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(fourthRootPriceRatio, fourthRootPriceRatioAfterStop, "FourthRootPriceRatio changed after stop");

        // Now warp a bit longer and check that it didn't keep changing.
        skip(duration / 2 + 1);

        uint96 fourthRootPriceRatioAfterWarp = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(
            fourthRootPriceRatio,
            fourthRootPriceRatioAfterWarp,
            "FourthRootPriceRatio changed after stop and warp"
        );
    }

    function testGetRate() public {
        vm.expectRevert(IReClammPool.ReClammPoolBptRateUnsupported.selector);
        ReClammPool(pool).getRate();
    }

    function testComputeBalance() public {
        vm.expectRevert(IReClammPool.NotImplemented.selector);
        ReClammPool(pool).computeBalance(new uint256[](0), 0, 0);
    }

    function testSetDailyPriceShiftExponentVaultUnlocked() public {
        vault.forceUnlock();

        uint256 newDailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT / 2;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.VaultIsNotLocked.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        uint256 newDailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT / 2;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponent() public {
        uint256 newDailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT / 2;

        uint256 dailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(newDailyPriceShiftExponent);
        uint256 actualNewDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.DailyPriceShiftExponentUpdated(actualNewDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualNewDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentPermissioned() public {
        uint256 newDailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT / 2;
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentUpdatingVirtualBalance() public {
        // Move the pool to the edge of the price interval, so the virtual balances will change over time.
        _setPoolBalances(0, 100e18);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        // Check if the last virtual balances stored in the pool are different from the current virtual balances.
        (uint256[] memory virtualBalancesBefore, ) = _computeCurrentVirtualBalances(pool);
        uint256[] memory lastVirtualBalancesBeforeSet = _getLastVirtualBalances(pool);

        assertNotEq(
            virtualBalancesBefore[daiIdx],
            lastVirtualBalancesBeforeSet[daiIdx],
            "DAI virtual balance remains unchanged"
        );
        // USDC virtual balance does not move.
        assertEq(virtualBalancesBefore[usdcIdx], lastVirtualBalancesBeforeSet[usdcIdx], "USDC virtual balance changed");

        uint256 newDailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT / 2;
        uint128 dailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(newDailyPriceShiftExponent).toUint128();
        uint256 actualNewDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit(address(pool));
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit(address(pool));
        emit IReClammPool.DailyPriceShiftExponentUpdated(actualNewDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualNewDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);

        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balances do not match");
    }

    function testSetCenterednessMarginVaultUnlocked() public {
        vault.forceUnlock();

        vm.prank(admin);
        vm.expectRevert(IReClammPool.VaultIsNotLocked.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMarginPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMargin() public {
        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(uint32(block.timestamp));

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(pool, "CenterednessMarginUpdated", abi.encode(_NEW_CENTEREDNESS_MARGIN));

        vm.prank(admin);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMarginAbove100() public {
        uint64 centerednessMarginAbove100 = uint64(FixedPoint.ONE + 1);
        vm.prank(admin);
        vm.expectRevert(IReClammPool.InvalidCenterednessMargin.selector);
        ReClammPoolMock(pool).setReClammCenterednessMargin(centerednessMarginAbove100);
    }

    function testSetCenterednessMarginPermissioned() public {
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testOutOfRangeBeforeSetCenterednessMargin() public {
        // Move the pool to the edge of the price interval, so it's out of range.
        _setPoolBalances(0, 100e18);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolOutsideTargetRange.selector);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
    }

    function testOutOfRangeAfterSetCenterednessMargin() public {
        // Move the pool close to the current margin.
        (uint256[] memory virtualBalances, ) = _computeCurrentVirtualBalances(pool);
        uint256 newBalanceB = 100e18;

        // Pool Centeredness = Ra * Vb / (Rb * Va). Make centeredness = margin, and you have the equation below.
        uint256 newBalanceA = (_DEFAULT_CENTEREDNESS_MARGIN * newBalanceB).mulDown(virtualBalances[a]) /
            virtualBalances[b];

        (uint256 newDaiBalance, uint256 newUsdcBalance) = _balanceABtoDaiUsdcBalances(newBalanceA, newBalanceB);
        _setPoolBalances(newDaiBalance, newUsdcBalance);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        // Exactly at boundary is still in range.
        assertTrue(ReClammPoolMock(pool).isPoolWithinTargetRange(), "Pool is out of range");
        (uint256 centeredness, ) = ReClammPoolMock(pool).computeCurrentPoolCenteredness();

        assertApproxEqRel(
            centeredness,
            _DEFAULT_CENTEREDNESS_MARGIN,
            1e16,
            "Pool centeredness is not close from margin"
        );

        // Margin will make the pool be out of range (since the current centeredness is near the default margin).
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolOutsideTargetRange.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testIsPoolInTargetRange() public {
        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);
        (uint256 lastVirtualBalanceA, uint256 lastVirtualBalanceB) = ReClammPool(pool).getLastVirtualBalances();
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        uint256 centerednessMargin = ReClammPool(pool).getCenterednessMargin();

        // Last should equal current.
        assertEq(lastVirtualBalanceA, virtualBalanceA, "last != current (A)");
        assertEq(lastVirtualBalanceB, virtualBalanceB, "last != current (B)");

        bool resultWithCurrentBalances = ReClammMath.isPoolWithinTargetRange(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB,
            centerednessMargin
        );
        assertTrue(resultWithCurrentBalances, "Expected value not in range");

        assertTrue(ReClammPool(pool).isPoolWithinTargetRange(), "Actual value not in range");

        uint256[] memory newLastVirtualBalances = new uint256[](2);
        newLastVirtualBalances[a] = lastVirtualBalanceA / 1000;
        newLastVirtualBalances[b] = lastVirtualBalanceB;

        bool resultWithLastBalances = ReClammMath.isPoolWithinTargetRange(
            balancesScaled18,
            newLastVirtualBalances[a],
            newLastVirtualBalances[b],
            centerednessMargin
        );

        assertFalse(resultWithLastBalances, "Expected value still in range");

        ReClammPoolMock(pool).setLastVirtualBalances(newLastVirtualBalances);

        assertFalse(ReClammPool(pool).isPoolWithinTargetRange(), "Actual value still in range");
    }

    function testInRangeUpdatingVirtualBalancesSetCenterednessMargin() public {
        vm.prank(admin);
        // Start updating virtual balances.
        ReClammPool(pool).startPriceRatioUpdate(2e18, block.timestamp, block.timestamp + 3 days);

        vm.warp(block.timestamp + 6 hours);

        // Check if the last virtual balances stored in the pool are different from the current virtual balances.
        (uint256[] memory virtualBalancesBefore, ) = _computeCurrentVirtualBalances(pool);
        uint256[] memory lastVirtualBalancesBeforeSet = _getLastVirtualBalances(pool);

        assertNotEq(
            virtualBalancesBefore[daiIdx],
            lastVirtualBalancesBeforeSet[daiIdx],
            "DAI virtual balance remains unchanged"
        );
        assertNotEq(
            virtualBalancesBefore[usdcIdx],
            lastVirtualBalancesBeforeSet[usdcIdx],
            "USDC virtual balance remains unchanged"
        );

        vm.expectEmit(address(pool));
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit(address(pool));
        emit IReClammPool.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "CenterednessMarginUpdated", abi.encode(_NEW_CENTEREDNESS_MARGIN));

        vm.prank(admin);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balance does not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balance does not match");
    }

    function testDynamicGetterBeforeInitialized() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        // Should not revert.
        ReClammPool(pool).getReClammPoolDynamicData();
    }

    function testComputePriceRangeBeforeInitialized() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        assertEq(minPrice, _DEFAULT_MIN_PRICE);
        assertEq(maxPrice, _DEFAULT_MAX_PRICE);
    }

    function testComputeCurrentVirtualBalancesBeforeInitialized() public {
        address newPool = _createUninitializedPool();

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(newPool).computeCurrentVirtualBalances();
    }

    function testComputeCurrentFourthRootPriceRatioBeforeInitialized() public {
        address newPool = _createUninitializedPool();

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(newPool).computeCurrentFourthRootPriceRatio();
    }

    function testComputeCurrentPriceRatioBeforeInitialized() public {
        address newPool = _createUninitializedPool();

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(newPool).computeCurrentPriceRatio();
    }

    function testIsPoolWithinTargetRangeBeforeInitialized() public {
        address newPool = _createUninitializedPool();

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(newPool).isPoolWithinTargetRange();
    }

    function testComputeCurrentPoolCenterednessBeforeInitialized() public {
        address newPool = _createUninitializedPool();

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(newPool).computeCurrentPoolCenteredness();
    }

    function _createUninitializedPool() internal returns (address newPool) {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (newPool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");
    }

    function testComputePriceRangeAfterInitialized() public view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is initialized");
        assertFalse(vault.isUnlocked(), "Vault is unlocked");

        // Should still be the initial values as nothing has changed.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        assertApproxEqRel(minPrice, _DEFAULT_MIN_PRICE, 0.01e16, "Incorrect min price");
        assertApproxEqRel(maxPrice, _DEFAULT_MAX_PRICE, 0.01e16, "Incorrect max price");
    }

    function testCreateWithInvalidMinPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: 0,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateWithTargetUnderMinPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1750e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateWithInvalidMaxPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 0,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateWithTargetOverMaxPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 3500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateWithInvalidTargetPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 0,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreatePoolWithPriceRatioBelowMin() public {
        uint256 minPrice = 1000e18;
        uint256 maxPrice = minPrice.mulDown(ReClammPoolFactoryLib.MIN_PRICE_RATIO) - 1;
        uint256 targetPrice = (minPrice + maxPrice) / 2;

        // Override pool factory (we want the real one, not the mock factory).
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);

        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc), address(dai)].toMemoryArray().asIERC20()
        );

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: alice });

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: minPrice,
            initialMaxPrice: maxPrice,
            initialTargetPrice: targetPrice,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens, rateProviders);

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioBelowMin.selector, maxPrice.divDown(minPrice)));
        poolFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
    }

    function testCreatePoolWithPriceRatioAboveMax() public {
        uint256 minPrice = 1000e18;
        uint256 maxPrice = minPrice.mulDown(ReClammPoolFactoryLib.MAX_PRICE_RATIO + 1);
        uint256 targetPrice = (minPrice + maxPrice) / 2;

        // Override pool factory (we want the real one, not the mock factory).
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);

        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc), address(dai)].toMemoryArray().asIERC20()
        );

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: alice });

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: minPrice,
            initialMaxPrice: maxPrice,
            initialTargetPrice: targetPrice,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens, rateProviders);

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioAboveMax.selector, maxPrice.divDown(minPrice)));
        poolFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            1e16, // centeredness margin
            bytes32(saltNumber++)
        );
    }

    function testCreateStandalonePoolWithInvalidPriceRatio() public {
        uint256 minPrice = 1000e18;
        uint256 maxPrice = minPrice.mulDown(ReClammPoolFactoryLib.MIN_PRICE_RATIO) - 1;
        uint256 targetPrice = (minPrice + maxPrice) / 2;
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: 0.2e18,
            initialMinPrice: minPrice,
            initialMaxPrice: maxPrice,
            initialTargetPrice: targetPrice,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.PriceRatioBelowMin.selector, maxPrice.divDown(minPrice)));
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreatePoolWithDailyPriceShiftExponentTooHigh() public {
        // Override pool factory (we want the real one, not the mock factory).
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);

        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc), address(dai)].toMemoryArray().asIERC20()
        );

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: alice });

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens, rateProviders);

        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooHigh.selector);
        poolFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT + 1,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
    }

    function testCreateStandalonePoolWithDailyPriceShiftExponentTooHigh() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT + 1,
            centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN,
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooHigh.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateStandalonePoolWithDailyPriceShiftExponentTooLow() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT - 1,
            centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN,
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooLow.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreateStandalonePoolWithDailyPriceShiftExponentZero() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "ZERO_SHIFT",
            version: "1",
            dailyPriceShiftExponent: 0,
            centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN,
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        // Zero is a valid configuration (disables price shifting). Should not revert.
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testCreatePoolWithCenterednessMarginTooHigh() public {
        // Override pool factory (we want the real one, not the mock factory).
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);

        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc), address(dai)].toMemoryArray().asIERC20()
        );

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: alice });

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens, rateProviders);

        vm.expectRevert(IReClammPool.InvalidCenterednessMargin.selector);
        poolFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            ReClammPoolFactoryLib.MAX_CENTEREDNESS_MARGIN + 1,
            bytes32(saltNumber++)
        );
    }

    function testCreateStandalonePoolWithCenterednessMarginTooHigh() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            centerednessMargin: uint64(ReClammPoolFactoryLib.MAX_CENTEREDNESS_MARGIN + 1),
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammPool.InvalidCenterednessMargin.selector);
        deployStandaloneReClammPool(params, vault, _helper);
    }

    function testOnBeforeInitializeEvents() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        ReClammPoolImmutableData memory data = ReClammPool(newPool).getReClammPoolImmutableData();

        (, , , uint256 priceRatio) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            data.initialMinPrice,
            data.initialMaxPrice,
            data.initialTargetPrice
        );

        uint256 fourthRootPriceRatio = ReClammMath.fourthRootScaled18(priceRatio);

        uint128 dailyPriceShiftBase = ReClammMath
            .toDailyPriceShiftBase(data.initialDailyPriceShiftExponent)
            .toUint128();
        uint256 actualDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit(newPool);
        emit IReClammPool.PriceRatioStateUpdated(
            fourthRootPriceRatio,
            fourthRootPriceRatio,
            block.timestamp,
            block.timestamp
        );

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "PriceRatioStateUpdated",
            abi.encode(fourthRootPriceRatio, fourthRootPriceRatio, block.timestamp, block.timestamp)
        );

        vm.expectEmit(newPool);
        emit IReClammPool.DailyPriceShiftExponentUpdated(actualDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.expectEmit(newPool);
        emit IReClammPool.CenterednessMarginUpdated(data.initialCenterednessMargin);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "CenterednessMarginUpdated",
            abi.encode(data.initialCenterednessMargin)
        );

        vm.expectEmit(newPool);
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(newPool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.prank(alice);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        // Can't call `onBeforeInitialize` twice.
        vm.prank(address(vault));
        vm.expectRevert(IReClammPool.PoolAlreadyInitialized.selector);
        ReClammPool(newPool).onBeforeInitialize(_initialBalances, "");
    }

    function testSetDailyPriceShiftExponentTooHigh() public {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        uint256 newDailyPriceShiftExponent = data.maxDailyPriceShiftExponent + 1;

        vm.prank(admin);
        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooHigh.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentTooLow() public {
        // Any nonzero value below the integer-division threshold (124649) silently truncates to zero
        // in toDailyPriceShiftBase. The validation rejects these.
        vm.prank(admin);
        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooLow.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT - 1);
    }

    function testSetDailyPriceShiftExponentZeroAllowed() public {
        // Zero explicitly disables price shifting and should not revert.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(0);
        assertEq(ReClammPool(pool).getDailyPriceShiftExponent(), 0);
    }

    function testSetDailyPriceShiftExponentAtMinimum() public {
        // The minimum nonzero value should be accepted.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT);
        assertGt(ReClammPool(pool).getDailyPriceShiftExponent(), 0);
    }

    function testSetLastVirtualBalances() public {
        uint256 virtualBalanceA = 10000e18;
        uint256 virtualBalanceB = 12000e18;

        vm.expectEmit(pool);
        emit IReClammPool.VirtualBalancesUpdated(virtualBalanceA, virtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "VirtualBalancesUpdated", abi.encode(virtualBalanceA, virtualBalanceB));

        ReClammPoolMock(pool).setLastVirtualBalances([virtualBalanceA, virtualBalanceB].toMemoryArray());
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);

        assertEq(lastVirtualBalances[a], virtualBalanceA, "Invalid last virtual balance A");
        assertEq(lastVirtualBalances[b], virtualBalanceB, "Invalid last virtual balance B");
    }

    function testSetLastVirtualBalances__Fuzz(uint256 virtualBalanceA, uint256 virtualBalanceB) public {
        virtualBalanceA = bound(virtualBalanceA, 1, type(uint128).max);
        virtualBalanceB = bound(virtualBalanceB, 1, type(uint128).max);

        ReClammPoolMock(pool).setLastVirtualBalances([virtualBalanceA, virtualBalanceB].toMemoryArray());
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);

        assertEq(lastVirtualBalances[a], virtualBalanceA, "Invalid last virtual balance A");
        assertEq(lastVirtualBalances[b], virtualBalanceB, "Invalid last virtual balance B");
    }

    function testInitializeRangeErrors() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        uint256[] memory highRatioAmounts = _initialBalances;
        highRatioAmounts[a] = 1e18;

        uint256 snapshotId = vm.snapshotState();

        vm.expectRevert(IReClammPool.BalanceRatioExceedsTolerance.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, highRatioAmounts, 0, false, bytes(""));

        vm.revertToState(snapshotId);

        uint256[] memory lowRatioAmounts = _initialBalances;
        lowRatioAmounts[b] = 1e18;

        vm.expectRevert(IReClammPool.BalanceRatioExceedsTolerance.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, lowRatioAmounts, 0, false, bytes(""));
    }

    function testInitializationTokenErrors() public {
        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        address[] memory tokens = [address(usdc), address(dai)].toMemoryArray();
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());
        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens);

        PoolRoleAccounts memory roleAccounts;

        // Standard tokens, one includes rate in the price.
        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: true,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );

        // Repeat for the other one.
        priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: true
        });

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
    }

    function testInvalidStartTime() public {
        ReClammPoolDynamicData memory data = IReClammPool(pool).getReClammPoolDynamicData();

        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp - 100; // invalid

        // Fail `priceRatioUpdateStartTime > priceRatioUpdateEndTime`.
        vm.expectRevert(IReClammPool.InvalidStartTime.selector);
        ReClammPoolMock(pool).manualStartPriceRatioUpdate(
            data.endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        priceRatioUpdateEndTime = block.timestamp + 100; // valid

        // Fail `priceRatioUpdateStartTime < block.timestamp`.
        vm.warp(priceRatioUpdateStartTime + 1);

        vm.expectRevert(IReClammPool.InvalidStartTime.selector);
        ReClammPoolMock(pool).manualStartPriceRatioUpdate(
            data.endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testDailyPriceShiftExponentHighPrice__Fuzz(uint256 exponent) public {
        // 1. Fuzz the exponent in the range [10e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT]
        exponent = bound(exponent, 10e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT);

        // 2. Set the daily price shift exponent on the pool (must be admin, and the vault must be locked)
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(exponent);

        // 3. Swap all of token B for token A using the router, with amountOut = current balance of A
        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[b],
            tokens[a],
            balances[a],
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Skip 1 second, so the virtual balances are updated in the pool.
        skip(1 seconds);

        (uint256 minPriceBefore, uint256 maxPriceBefore) = ReClammPool(pool).computeCurrentPriceRange();

        skip(1 days);

        (uint256 minPriceAfter, uint256 maxPriceAfter) = ReClammPool(pool).computeCurrentPriceRange();

        // Calculate expected min price after 1 day
        // The price should move by a factor of 2^exponent (using exp2 from FixedPoint)
        uint256 expectedMinPrice = minPriceBefore.mulDown(uint256(2e18).powDown(exponent));
        uint256 expectedMaxPrice = maxPriceBefore.mulDown(uint256(2e18).powDown(exponent));

        // Allow for some rounding error
        assertApproxEqRel(minPriceAfter, expectedMinPrice, 1e14, "Min price did not move as expected");
        assertApproxEqRel(maxPriceAfter, expectedMaxPrice, 1e14, "Max price did not move as expected");
    }

    function testDailyPriceShiftExponentLowPrice__Fuzz(uint256 exponent) public {
        // 1. Fuzz the exponent in the range [10e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT]
        exponent = bound(exponent, 10e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT);

        // 2. Set the daily price shift exponent on the pool (must be admin and vault locked)
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(exponent);

        // 3. Swap all of token B for token A using the router, with amountOut = current balance of A
        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[a],
            tokens[b],
            balances[b],
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Skip 1 second, so the virtual balances are updated in the pool.
        skip(1 seconds);

        // Get min price before swap
        (uint256 minPriceBefore, uint256 maxPriceBefore) = ReClammPool(pool).computeCurrentPriceRange();

        // 4. Advance time by 1 day
        skip(1 days);

        // 5. Check that the new min price is minPriceBefore * 2^exponent
        (uint256 minPriceAfter, uint256 maxPriceAfter) = ReClammPool(pool).computeCurrentPriceRange();

        // Calculate expected min price after 1 day
        // The price should move by a factor of 2^exponent (using exp2 from FixedPoint)
        uint256 expectedMinPrice = minPriceBefore.divDown(uint256(2e18).powDown(exponent));
        uint256 expectedMaxPrice = maxPriceBefore.divDown(uint256(2e18).powDown(exponent));

        // Allow for some rounding error
        assertApproxEqRel(minPriceAfter, expectedMinPrice, 1e14, "Min price did not move as expected");
        assertApproxEqRel(maxPriceAfter, expectedMaxPrice, 1e14, "Max price did not move as expected");
    }

    /**
     * @notice Demonstrates that price range movement exceeds the VB decay rate when Ro > 0 (high price direction).
     * @dev The existing `testDailyPriceShiftExponentHighPrice__Fuzz` and `LowPrice__Fuzz` tests drain the overvalued
     * real balance to zero before measuring, which is the one case where price movement exactly equals VB decay.
     * This test performs a partial drain (leaving Ro > 0) and verifies that the actual price movement is strictly
     * faster than `2^exponent` per day, then checks the exact analytical relationship.
     *
     * The excess speed comes from the undervalued VB adjusting when the overvalued VB decays: when Ro > 0, both
     * virtual balances move, compounding the price effect. A useful heuristic: with default pool parameters
     * (Q0 = 2, lambda ~ 0.5 at 100% exponent), the excess is roughly 1 + 2*rho, where
     * rho = Ro / ((Q0-1) * Vo). Each 1% of rho adds about 2% extra price-range speed beyond the calibrated rate.
     *
     * The excess is effectively unbounded: the exact formula has ((Q0-1)*lambda*Vo - Ro) in the denominator,
     * which shrinks toward zero as rho approaches the centeredness clamp. The clamp prevents a singularity,
     * but near-clamp states can see excess factors of 4-5x with default parameters (i.e., prices moving
     * 8-10x/day instead of the calibrated 2x). The 80% drain in this test is a moderate case (rho ~ 5-12%).
     */
    function testPriceShiftFasterThanExponentWhenRoPositiveHighPrice() public {
        uint256 exponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT;

        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        // Partial drain: remove 80% of token A (enough to go out of range with the default 20% centeredness
        // margin, but leaves the overvalued side's real balance positive). Adjust if defaults change.
        uint256 amountAOut = (balances[a] * 80) / 100;

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[b],
            tokens[a],
            amountAOut,
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        // Confirm we're out of range but token A is not fully drained.
        (, , uint256[] memory postSwapBalances, ) = vault.getPoolTokenInfo(pool);
        assertGt(postSwapBalances[a], 0, "Token A should not be fully drained");
        assertFalse(ReClammPool(pool).isPoolWithinTargetRange(), "Pool should be out of range");

        // Snapshot stored pool state for the analytical formula.
        ReClammPoolDynamicData memory dynData = ReClammPool(pool).getReClammPoolDynamicData();

        // Skip 1 second to commit the post-swap state, then record prices.
        skip(1 seconds);

        (uint256 minPriceBefore, uint256 maxPriceBefore) = ReClammPool(pool).computeCurrentPriceRange();

        skip(1 days);

        (uint256 minPriceAfter, uint256 maxPriceAfter) = ReClammPool(pool).computeCurrentPriceRange();

        // After draining A, the pool is below center (isPoolAboveCenter = false). The overvalued VB is A
        // (the scarce side whose virtual balance decays). Prices (B/A) move upward as Va decays.
        // With Ro > 0 the actual movement is strictly faster than the VB-only prediction.
        uint256 expectedMinPrice = minPriceBefore.mulDown(uint256(2e18).powDown(exponent));
        uint256 expectedMaxPrice = maxPriceBefore.mulDown(uint256(2e18).powDown(exponent));

        // With default parameters and an 80% drain, prices move ~11% faster than the VB-only prediction
        // (2.23x vs 2x per day). The exact percentage depends on Ro/Vo and Q0; see the analytical check below.
        assertGt(minPriceAfter, expectedMinPrice, "Min price should move faster than 2^exponent when Ro > 0");
        assertGt(maxPriceAfter, expectedMaxPrice, "Max price should move faster than 2^exponent when Ro > 0");

        // Quantify the excess. The price shift decomposes into two multiplicative parts:
        //   1. (1/lambda): the calibrated part from overvalued VB decay.
        //   2. Vu_after/Vu_before: the uncalibrated adjustment of the undervalued VB.
        // When Ro = 0 the Vu formula reduces to Ru/(Q0-1), independent of Vo, so Vu doesn't change and
        // the excess is 1 (the degenerate case tested by the fuzz tests). When Ro > 0, decaying Vo also
        // shifts Vu, compounding the price effect. Ru cancels in the Vu ratio, leaving:
        //   excess = [(lambda*Vo + Ro) / (Vo + Ro)] x [((Q0-1)*Vo - Ro) / ((Q0-1)*lambda*Vo - Ro)]
        // To first order in rho = Ro/((Q0-1)*Vo): excess ~ 1 + rho*Q0*(1-lambda)/lambda.
        // With defaults (Q0=2, lambda~0.5) that is roughly 1 + 2*rho.
        {
            uint256 Vo = dynData.lastVirtualBalances[a];
            uint256 Ro = dynData.balancesLiveScaled18[a];
            uint256 Q0 = mathMock.sqrtScaled18(
                mathMock.computePriceRatio(
                    dynData.balancesLiveScaled18,
                    dynData.lastVirtualBalances[a],
                    dynData.lastVirtualBalances[b]
                )
            );
            uint256 lambda = dynData.dailyPriceShiftBase.powDown(86400 * FixedPoint.ONE);

            uint256 D = Q0 - FixedPoint.ONE;
            uint256 lambdaVo = lambda.mulDown(Vo);

            // excess = [(lambda*Vo + Ro) / (Vo + Ro)] x [((Q0-1)*Vo - Ro) / ((Q0-1)*lambda*Vo - Ro)]
            uint256 analyticalExcess = (lambdaVo + Ro).divDown(Vo + Ro).mulDown(Vo.mulDown(D) - Ro).divDown(
                lambdaVo.mulDown(D) - Ro
            );

            uint256 predictedFactor = FixedPoint.ONE.divDown(lambda).mulDown(analyticalExcess);

            assertApproxEqRel(
                minPriceAfter.divDown(minPriceBefore),
                predictedFactor,
                1e14,
                "Min price factor should match analytical formula"
            );
            assertApproxEqRel(
                maxPriceAfter.divDown(maxPriceBefore),
                predictedFactor,
                1e14,
                "Max price factor should match analytical formula"
            );
        }
    }

    /// @notice Same as the high-price variant, but drains token B to test the low-price direction.
    function testPriceShiftFasterThanExponentWhenRoPositiveLowPrice() public {
        uint256 exponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT;

        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        // Partial drain: remove 80% of token B. Adjust if defaults change.
        uint256 amountBOut = (balances[b] * 80) / 100;

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[a],
            tokens[b],
            amountBOut,
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        (, , uint256[] memory postSwapBalances, ) = vault.getPoolTokenInfo(pool);
        assertGt(postSwapBalances[b], 0, "Token B should not be fully drained");
        assertFalse(ReClammPool(pool).isPoolWithinTargetRange(), "Pool should be out of range");

        // Snapshot stored pool state for the analytical formula.
        ReClammPoolDynamicData memory dynData = ReClammPool(pool).getReClammPoolDynamicData();

        skip(1 seconds);

        (uint256 minPriceBefore, uint256 maxPriceBefore) = ReClammPool(pool).computeCurrentPriceRange();

        skip(1 days);

        (uint256 minPriceAfter, uint256 maxPriceAfter) = ReClammPool(pool).computeCurrentPriceRange();

        // After draining B, the pool is above center (isPoolAboveCenter = true). The overvalued VB is B
        // (the scarce side whose virtual balance decays). Prices (B/A) move downward.
        // With Ro > 0 the actual movement is strictly faster than the VB-only prediction.
        uint256 expectedMinPrice = minPriceBefore.divDown(uint256(2e18).powDown(exponent));
        uint256 expectedMaxPrice = maxPriceBefore.divDown(uint256(2e18).powDown(exponent));

        // With default parameters and an 80% drain, prices drop ~21% more than the VB-only prediction
        // (0.39x vs 0.50x per day). Larger than the high-price test because Rb/Vb > Ra/Va in this pool.
        assertLt(minPriceAfter, expectedMinPrice, "Min price should move faster than 1/2^exponent when Ro > 0");
        assertLt(maxPriceAfter, expectedMaxPrice, "Max price should move faster than 1/2^exponent when Ro > 0");

        // Quantify the excess. Same decomposition as the high-price test (see comment there):
        //   price factor = lambda x (Vu_before/Vu_after)
        // The Vu ratio (excess) is the reciprocal of the below-center form because price moves the
        // opposite direction. Ru cancels, leaving:
        //   excess = [((Q0-1)*lambda*Vo - Ro) / ((Q0-1)*Vo - Ro)] x [(Vo + Ro) / (lambda*Vo + Ro)]
        // Same first-order bound: excess ~ 1 - rho*Q0*(1-lambda)/lambda (< 1 when Ro > 0).
        {
            uint256 Vo = dynData.lastVirtualBalances[b];
            uint256 Ro = dynData.balancesLiveScaled18[b];
            uint256 Q0 = mathMock.sqrtScaled18(
                mathMock.computePriceRatio(
                    dynData.balancesLiveScaled18,
                    dynData.lastVirtualBalances[a],
                    dynData.lastVirtualBalances[b]
                )
            );
            uint256 lambda = dynData.dailyPriceShiftBase.powDown(86400 * FixedPoint.ONE);

            uint256 D = Q0 - FixedPoint.ONE;
            uint256 lambdaVo = lambda.mulDown(Vo);

            // excess = [((Q0-1)*lambda*Vo - Ro) / ((Q0-1)*Vo - Ro)] x [(Vo + Ro) / (lambda*Vo + Ro)]
            uint256 analyticalExcess = (lambdaVo.mulDown(D) - Ro).divDown(Vo.mulDown(D) - Ro).mulDown(Vo + Ro).divDown(
                lambdaVo + Ro
            );

            uint256 predictedFactor = lambda.mulDown(analyticalExcess);

            assertApproxEqRel(
                minPriceAfter.divDown(minPriceBefore),
                predictedFactor,
                1e14,
                "Min price factor should match analytical formula"
            );
            assertApproxEqRel(
                maxPriceAfter.divDown(maxPriceBefore),
                predictedFactor,
                1e14,
                "Max price factor should match analytical formula"
            );
        }
    }

    function testPriceRangeShiftStop__Fuzz(uint256 margin, uint256 priceShiftExponent, uint256 longDelay) public {
        uint256 shortDelay = 5 hours;

        margin = bound(margin, 1e16, _MAX_CENTEREDNESS_MARGIN);
        priceShiftExponent = bound(priceShiftExponent, 1e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT);
        longDelay = bound(longDelay, 30 days, 100 days); // will get capped

        vm.startPrank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(priceShiftExponent);
        ReClammPoolMock(pool).manualSetCenterednessMargin(margin);
        vm.stopPrank();

        // Swap all of token B for token A using the router, getting almost all of the balance of B.
        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[a],
            tokens[b],
            balances[b] - 1e18, // Swap almost all of B
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        (, , , uint256[] memory balancesScaled18AfterSwap) = vault.getPoolTokenInfo(pool);

        (uint256 poolCenterednessAfterSwap, ) = ReClammPool(pool).computeCurrentPoolCenteredness();
        assertApproxEqAbs(poolCenterednessAfterSwap, 0, 0.5e16, "Pool centeredness after swap is not close to 0%");
        assertFalse(ReClammPool(pool).isPoolWithinTargetRange(), "Pool is still within target range after swap");

        // Wait some time, verify that the price is moving.
        skip(shortDelay);

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = ReClammPool(pool)
            .computeCurrentVirtualBalances();

        assertTrue(changed, "Virtual balances did not change after short delay");
        (uint256 centerednessAfterShortDelay, bool isPoolAboveCenter) = ReClammMath.computeCenteredness(
            balancesScaled18AfterSwap,
            currentVirtualBalanceA,
            currentVirtualBalanceB
        );
        assertGt(
            centerednessAfterShortDelay,
            poolCenterednessAfterSwap,
            "Centeredness did not increase with respect to the starting point"
        );
        assertGt(centerednessAfterShortDelay, poolCenterednessAfterSwap, "Centeredness did not increase");
        assertLt(centerednessAfterShortDelay, margin, "Centeredness increased past the margin");
        assertTrue(isPoolAboveCenter, "Pool is not above the center");

        // We're way past the margin right now, but we should not go past 100%.
        skip(longDelay);

        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = ReClammPool(pool).computeCurrentVirtualBalances();
        assertTrue(changed, "Virtual balances did not change after long delay");
        uint256 centerednessAfterLongDelay;
        (centerednessAfterLongDelay, isPoolAboveCenter) = ReClammMath.computeCenteredness(
            balancesScaled18AfterSwap,
            currentVirtualBalanceA,
            currentVirtualBalanceB
        );
        assertGt(
            centerednessAfterLongDelay,
            centerednessAfterShortDelay,
            "Centeredness did not increase after long delay"
        );

        assertTrue(isPoolAboveCenter, "Pool is not above the center (changed sides)");
        assertLt(centerednessAfterLongDelay, 100e16, "Centeredness did not stay below 100%");

        // Wait even more; the virtual balances should not change anymore.
        skip(10 days);
        (uint256 finalVirtualBalanceA, uint256 finalVirtualBalanceB, ) = ReClammPool(pool)
            .computeCurrentVirtualBalances();
        assertEq(finalVirtualBalanceA, currentVirtualBalanceA, "Final virtual balance A changed");
        assertEq(finalVirtualBalanceB, currentVirtualBalanceB, "Final virtual balance B changed");
    }

    function testPriceRangeShiftStopAt100__Fuzz(uint256 margin) public {
        margin = bound(margin, 1e16, _MAX_CENTEREDNESS_MARGIN);

        vm.startPrank(admin);
        ReClammPoolMock(pool).manualSetCenterednessMargin(margin);
        ReClammPool(pool).setDailyPriceShiftExponent(_MAX_DAILY_PRICE_SHIFT_EXPONENT);
        vm.stopPrank();

        // Swap all of token B for token A using the router, getting almost all of the balance of B.
        (IERC20[] memory tokens, , uint256[] memory balances, ) = vault.getPoolTokenInfo(pool);

        vm.prank(alice);
        router.swapSingleTokenExactOut(
            pool,
            tokens[a],
            tokens[b],
            balances[b] - 1e18, // Swap a big chunk of token balances to get closer to the edge
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        (, , , uint256[] memory balancesScaled18AfterSwap) = vault.getPoolTokenInfo(pool);

        (uint256 poolCenterednessAfterSwap, ) = ReClammPool(pool).computeCurrentPoolCenteredness();
        assertApproxEqAbs(poolCenterednessAfterSwap, 0, 0.5e16, "Pool centeredness after swap is not close to 0%");
        assertFalse(ReClammPool(pool).isPoolWithinTargetRange(), "Pool is still within target range after swap");

        // We're way past the margin right now, but we should not go past 100%.
        skip(30 days);

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = ReClammPool(pool)
            .computeCurrentVirtualBalances();
        assertTrue(changed, "Virtual balances did not change after long delay");
        (uint256 centerednessAfterLongDelay, bool isPoolAboveCenter) = ReClammMath.computeCenteredness(
            balancesScaled18AfterSwap,
            currentVirtualBalanceA,
            currentVirtualBalanceB
        );
        assertApproxEqAbs(centerednessAfterLongDelay, 100e16, 0.0000001e16, "Centeredness did not stop at 100%");
        assertTrue(isPoolAboveCenter, "Pool is not above the center (changed sides)");
        assertLt(centerednessAfterLongDelay, 100e16, "Centeredness did not stay below 100%");

        // Wait even more; the virtual balances should not change anymore.
        skip(30 days);
        (uint256 finalVirtualBalanceA, uint256 finalVirtualBalanceB, ) = ReClammPool(pool)
            .computeCurrentVirtualBalances();
        assertEq(finalVirtualBalanceA, currentVirtualBalanceA, "Final virtual balance A changed");
        assertEq(finalVirtualBalanceB, currentVirtualBalanceB, "Final virtual balance B changed");
    }

    function testPoolCreator() public view {
        PoolRoleAccounts memory roleAccounts = vault.getPoolRoleAccounts(pool);

        assertEq(roleAccounts.poolCreator, alice, "Wrong pool creator");
    }

    function testUpdateVirtualBalancesUsesCurrentLiveBalances() public {
        // Set pool clearly out of range with A dominant (above center).
        _setPoolBalances(100e18, 5e18);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);
        skip(6 hours);

        uint256[] memory rawBalances = vault.getRawBalances(pool);
        uint256[] memory liveBalances = vault.getCurrentLiveBalances(pool);

        // Set stale lastBalancesLiveScaled18 to the mirror image: B dominant (below center).
        // This flips isAboveCenter, causing virtual balances to shift in the opposite direction.
        uint256[] memory staleLastLive = new uint256[](2);
        staleLastLive[a] = liveBalances[b]; // swap A and B values
        staleLastLive[b] = liveBalances[a];

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(pool);
        vault.manualSetPoolTokensAndBalances(pool, tokens, rawBalances, staleLastLive);

        (, , , uint256[] memory committedBalances) = vault.getPoolTokenInfo(pool);
        uint256[] memory currentLiveBalances = vault.getCurrentLiveBalances(pool);
        assertNotEq(committedBalances[a], currentLiveBalances[a], "No divergence between committed and live");

        (uint256 expectedFromLive, , ) = ReClammPoolMock(pool).computeCurrentVirtualBalances(currentLiveBalances);
        (uint256 expectedFromStale, , ) = ReClammPoolMock(pool).computeCurrentVirtualBalances(committedBalances);
        assertNotEq(expectedFromLive, expectedFromStale, "Virtual balance paths do not diverge");

        // Trigger a state-mutating operation to force `_updateVirtualBalances()` to commit the computed virtual
        // balances to storage. The exponent value is unchanged; this call is the mechanism to flush the time-adjusted
        // virtual balances so they can be read back via `getLastVirtualBalances()`.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(_DEFAULT_DAILY_PRICE_SHIFT_EXPONENT);

        // The stored virtual balance should exactly match what would be computed from live balances, confirming that
        // `_updateVirtualBalances` used `getCurrentLiveBalances()` rather than the stale committed balances
        // injected above.
        (uint256 storedA, ) = ReClammPool(pool).getLastVirtualBalances();
        assertEq(storedA, expectedFromLive, "Stored virtual balance A does not match live-balance computation");
    }

    function _createStandardPool(
        bool tokenAPriceIncludesRate,
        bool tokenBPriceIncludesRate,
        string memory label
    ) internal returns (address newPool) {
        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        address[] memory tokens = [address(usdc), address(dai)].toMemoryArray();
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());
        PoolRoleAccounts memory roleAccounts;

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: tokenBPriceIncludesRate
        });

        newPool = ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            vault.buildTokenConfig(sortedTokens),
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
        vm.label(newPool, label);
    }
}
