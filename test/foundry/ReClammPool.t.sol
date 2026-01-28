// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { ReClammPoolDynamicData, ReClammPoolImmutableData } from "../../contracts/interfaces/IReClammPoolExtension.sol";
import { IReClammPool, ReClammPoolParams, ReClammPriceParams } from "../../contracts/interfaces/IReClammPool.sol";
import { IReClammPoolExtension } from "../../contracts/interfaces/IReClammPoolExtension.sol";
import { PriceRatioState, ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactoryMock } from "../../contracts/test/ReClammPoolFactoryMock.sol";
import { IReClammPoolMain } from "../../contracts/interfaces/IReClammPoolMain.sol";
import { ReClammPoolExtension } from "../../contracts/ReClammPoolExtension.sol";
import { IReClammEvents } from "../../contracts/interfaces/IReClammEvents.sol";
import { IReClammErrors } from "../../contracts/interfaces/IReClammErrors.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { ReClammCommon } from "../../contracts/ReClammCommon.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

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

    function testOnRegisterOnlyVault() public {
        LiquidityManagement memory liquidityManagement;

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onRegister(address(this), address(this), new TokenConfig[](2), liquidityManagement);
    }

    function testOnSwapOnlyVault() public {
        PoolSwapParams memory request;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        ReClammPool(payable(pool)).onSwap(request);
    }

    function testOnBeforeInitializeOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onBeforeInitialize(new uint256[](2), bytes(""));
    }

    function testOnAfterInitializeOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterInitialize(new uint256[](2), 0, bytes(""));
    }
    function testOnBeforeAddLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onBeforeAddLiquidity(
            address(this),
            address(this),
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            0,
            new uint256[](2),
            bytes("")
        );
    }

    function testOnAfterAddLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterAddLiquidity(
            address(this),
            address(this),
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            new uint256[](2),
            0,
            new uint256[](2),
            bytes("")
        );
    }

    function testOnBeforeRemoveLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onBeforeRemoveLiquidity(
            address(this),
            address(this),
            RemoveLiquidityKind.PROPORTIONAL,
            1,
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );
    }

    function testOnAfterRemoveLiquidityOnlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterRemoveLiquidity(
            address(this),
            address(this),
            RemoveLiquidityKind.PROPORTIONAL,
            1,
            new uint256[](2),
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );
    }

    function testOnBeforeSwapOnlyVault() public {
        PoolSwapParams memory params;

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onBeforeSwap(params, address(this));
    }

    function testOnAfterSwapOnlyVault() public {
        AfterSwapParams memory params;

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterSwap(params);
    }

    function testComputeCurrentFourthRootPriceRatio() public view {
        uint256 fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, _initialFourthRootPriceRatio, "Invalid default fourthRootPriceRatio");
    }

    function testGetCenterednessMargin() public {
        uint256 centerednessMargin = IReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, _DEFAULT_CENTEREDNESS_MARGIN, "Invalid default centerednessMargin");

        vm.prank(admin);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);

        centerednessMargin = IReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, _NEW_CENTEREDNESS_MARGIN, "Invalid new centerednessMargin");
    }

    function testGetLastTimestamp() public {
        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(20e16);

        uint256 lastTimestampBeforeWarp = IReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampBeforeWarp, block.timestamp, "Invalid lastTimestamp before warp");

        skip(1 hours);
        uint256 lastTimestampAfterWarp = IReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampAfterWarp, lastTimestampBeforeWarp, "Invalid lastTimestamp after warp");

        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(30e16);

        uint256 lastTimestampAfterSetDailyPriceShiftExponent = IReClammPool(pool).getLastTimestamp();
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
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(dailyPriceShiftExponent);

        uint256 actualDailyPriceShiftDailyBase = IReClammPool(pool).getDailyPriceShiftBase();
        assertEq(actualDailyPriceShiftDailyBase, expectedDailyPriceShiftBase, "Invalid DailyPriceShiftBase");
    }

    function testGetDailyPriceShiftExponentToBase() public {
        uint256 dailyPriceRateExponent = 30e16;
        vm.prank(admin);
        uint256 actualDailyPriceShiftExponentReturned = ReClammPool(payable(pool)).setDailyPriceShiftExponent(
            dailyPriceRateExponent
        );

        uint256 actualDailyPriceShiftBase = IReClammPool(pool).getDailyPriceShiftBase();
        uint256 actualDailyPriceShiftExponent = IReClammPool(pool).getDailyPriceShiftExponent();
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
        PriceRatioState memory priceRatioState = IReClammPool(pool).getPriceRatioState();
        assertApproxEqAbs(
            priceRatioState.startFourthRootPriceRatio,
            _initialFourthRootPriceRatio,
            1e6,
            "Invalid default startFourthRootPriceRatio"
        );
        // Error tolerance of 1 million wei (price ratio is computed using the pool balances and may have a small error).
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

        uint256 oldFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio();
        uint256 newFourthRootPriceRatio = oldFourthRootPriceRatio.mulDown(90e16);
        uint256 newPriceRatio = _pow4(newFourthRootPriceRatio);
        uint256 newPriceRatioUpdateStartTime = block.timestamp;
        uint256 newPriceRatioUpdateEndTime = block.timestamp + 1 days;

        vm.prank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(
            newPriceRatio,
            newPriceRatioUpdateStartTime,
            newPriceRatioUpdateEndTime
        );

        priceRatioState = IReClammPool(pool).getPriceRatioState();
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
        uint256 newDailyPriceShiftExponent = 80e16;
        uint256 endPriceRatio = 16e18;
        uint256 endFourthRootPriceRatio = 2e18;
        uint256 newStaticSwapFeePercentage = 5e16;

        PriceRatioState memory state = PriceRatioState({
            startFourthRootPriceRatio: IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96(),
            endFourthRootPriceRatio: endFourthRootPriceRatio.toUint96(),
            priceRatioUpdateStartTime: block.timestamp.toUint32(),
            priceRatioUpdateEndTime: (block.timestamp + 3 days).toUint32()
        });

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.startPrank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            state.priceRatioUpdateStartTime,
            state.priceRatioUpdateEndTime
        );
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
        vault.setStaticSwapFeePercentage(pool, newStaticSwapFeePercentage);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours);

        uint256 currentPriceRatio = IReClammPool(pool).computeCurrentPriceRatio();
        uint96 currentFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        // Get initial dynamic data.
        ReClammPoolDynamicData memory data = IReClammPool(pool).getReClammPoolDynamicData();

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
        assertEq(data.totalSupply, IERC20(pool).totalSupply(), "Invalid total supply");

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
        ReClammPoolImmutableData memory data = IReClammPool(pool).getReClammPoolImmutableData();
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
        assertEq(data.hookContract, poolHooksContract, "Invalid hook contract");
        assertTrue(data.externalHookHasBeforeInitialize, "External hook beforeInitialize flag not set");
        assertTrue(data.externalHookHasBeforeAddLiquidity, "External hook beforeAddLiquidity flag not set");
        assertTrue(data.externalHookHasBeforeRemoveLiquidity, "External hook beforeRemoveLiquidity flag not set");

        // Check operating limit parameters.
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
        ReClammPool(payable(pool)).startPriceRatioUpdate(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.expectRevert(IReClammErrors.PoolNotInitialized.selector);
        vm.prank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioShortDuration() public {
        uint96 endPriceRatio = 16e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 1 days;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(IReClammErrors.PriceRatioUpdateDurationTooShort.selector);
        vm.prank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testSetFourthRootPriceRatioSmallDelta() public {
        uint256 delta = _MIN_PRICE_RATIO_DELTA - 1;
        uint96 startPriceRatio = IReClammPool(pool).computeCurrentPriceRatio().toUint96();
        uint96 endPriceRatio = startPriceRatio + delta.toUint96();
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp);
        uint32 duration = 1 days;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(abi.encodeWithSelector(IReClammErrors.PriceRatioDeltaBelowMin.selector, delta));
        vm.prank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testSetFourthRootPriceRatioTooFast() public {
        uint256 newPriceRatio = 64e18;
        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp + 1 days;

        // The previous approach (calculating the exact point where it would be too fast) no longer works when we're
        // passing in the actual price ratio, since the error in pow >> 1-2 wei delta that would meaningfully check the
        // boundary. And the error is only raised in the external function, so we can't use the mock here. Best we can
        // do is set a large update that would be too fast, and show that the error is triggered.
        vm.expectRevert(IReClammErrors.PriceRatioUpdateTooFast.selector);
        vm.prank(admin);
        ReClammPool(payable(pool)).startPriceRatioUpdate(
            newPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testSetFourthRootPriceRatio() public {
        uint96 endPriceRatio = 16e18;
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 3 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammEvents.PriceRatioStateUpdated(
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
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
        assertEq(actualPriceRatioUpdateStartTime, block.timestamp, "Invalid updated actual price ratio start time");

        skip(duration / 2);
        uint96 fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
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
        fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
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
        uint32 duration = 3 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        // Events:
        // - Timestamp update
        // - Price ratio state update
        // Virtual balances don't change in this case.
        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammEvents.PriceRatioStateUpdated(
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
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
        assertEq(actualPriceRatioUpdateStartTime, block.timestamp, "Invalid updated actual price ratio start time");

        skip(duration / 2);
        uint96 fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
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
        endPriceRatio = 81e18;
        endFourthRootPriceRatio = 3e18;
        timeOffset = 1 hours;
        priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        duration = 6 days;
        priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        startFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = IReClammPool(pool)
            .computeCurrentVirtualBalances();

        // Events:
        // - Virtual balances update
        // - Timestamp update
        // - Price ratio state update
        vm.expectEmit(pool);
        emit IReClammEvents.VirtualBalancesUpdated(currentVirtualBalanceA, currentVirtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "VirtualBalancesUpdated",
            abi.encode(currentVirtualBalanceA, currentVirtualBalanceB)
        );

        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammEvents.PriceRatioStateUpdated(
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
        actualPriceRatioUpdateStartTime = ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        vm.warp(priceRatioUpdateEndTime + 1);
        fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
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
        ReClammPool(payable(pool)).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdatePoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.expectRevert(IReClammErrors.PoolNotInitialized.selector);
        vm.prank(admin);
        ReClammPool(payable(pool)).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdatePriceRatioNotUpdating() public {
        skip(1 hours);
        vm.expectRevert(IReClammErrors.PriceRatioNotUpdating.selector);
        vm.prank(admin);
        ReClammPool(payable(pool)).stopPriceRatioUpdate();
    }

    function testStopPriceRatioUpdate() public {
        uint96 endPriceRatio = 16e18;
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 3 days;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        vm.prank(admin);
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(payable(pool)).startPriceRatioUpdate(
            endPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        skip(duration / 2);
        uint96 fourthRootPriceRatio = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
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

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = IReClammPool(pool)
            .computeCurrentVirtualBalances();

        // Events:
        // - Virtual balances update
        // - Timestamp update
        // - Price ratio state update
        vm.expectEmit(pool);
        emit IReClammEvents.VirtualBalancesUpdated(currentVirtualBalanceA, currentVirtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "VirtualBalancesUpdated",
            abi.encode(currentVirtualBalanceA, currentVirtualBalanceB)
        );

        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        // Price ratio update event with current value and timestamp.
        vm.expectEmit();
        emit IReClammEvents.PriceRatioStateUpdated(
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
        ReClammPool(payable(pool)).stopPriceRatioUpdate();

        uint96 fourthRootPriceRatioAfterStop = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(fourthRootPriceRatio, fourthRootPriceRatioAfterStop, "FourthRootPriceRatio changed after stop");

        // Now warp a bit longer and check that it didn't keep changing.
        skip(duration / 2 + 1);

        uint96 fourthRootPriceRatioAfterWarp = IReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(
            fourthRootPriceRatio,
            fourthRootPriceRatioAfterWarp,
            "FourthRootPriceRatio changed after stop and warp"
        );
    }

    function testGetRate() public {
        vm.expectRevert(IReClammErrors.ReClammPoolBptRateUnsupported.selector);
        IRateProvider(pool).getRate();
    }

    function testComputeBalance() public {
        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IBasePool(pool).computeBalance(new uint256[](0), 0, 0);
    }

    function testSetDailyPriceShiftExponentVaultUnlocked() public {
        vault.forceUnlock();

        uint256 newDailyPriceShiftExponent = 80e16;
        vm.prank(admin);
        vm.expectRevert(IReClammErrors.VaultIsNotLocked.selector);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        uint256 newDailyPriceShiftExponent = 80e16;
        vm.prank(admin);
        vm.expectRevert(IReClammErrors.PoolNotInitialized.selector);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponent() public {
        uint256 newDailyPriceShiftExponent = 80e16;

        uint256 dailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(newDailyPriceShiftExponent);
        uint256 actualNewDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammEvents.DailyPriceShiftExponentUpdated(actualNewDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualNewDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.prank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentPermissioned() public {
        uint256 newDailyPriceShiftExponent = 80e16;
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentUpdatingVirtualBalance() public {
        // Move the pool to the edge of the price interval, so the virtual balances will change over time.
        _setPoolBalances(0, 100e18);
        ReClammPoolMock(payable(pool)).setLastTimestamp(block.timestamp);

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

        uint256 newDailyPriceShiftExponent = 80e16;
        uint128 dailyPriceShiftBase = ReClammMath.toDailyPriceShiftBase(newDailyPriceShiftExponent).toUint128();
        uint256 actualNewDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit(address(pool));
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit(address(pool));
        emit IReClammEvents.DailyPriceShiftExponentUpdated(actualNewDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualNewDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.prank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);

        assertEq(IReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);

        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balances do not match");
    }

    function testSetCenterednessMarginVaultUnlocked() public {
        vault.forceUnlock();

        vm.prank(admin);
        vm.expectRevert(IReClammErrors.VaultIsNotLocked.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMarginPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.prank(admin);
        vm.expectRevert(IReClammErrors.PoolNotInitialized.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMargin() public {
        vm.expectEmit();
        emit IReClammEvents.LastTimestampUpdated(uint32(block.timestamp));

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammEvents.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(pool, "CenterednessMarginUpdated", abi.encode(_NEW_CENTEREDNESS_MARGIN));

        vm.prank(admin);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMarginAbove100() public {
        uint64 centerednessMarginAbove100 = uint64(FixedPoint.ONE + 1);
        vm.prank(admin);
        vm.expectRevert(IReClammErrors.InvalidCenterednessMargin.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(centerednessMarginAbove100);
    }

    function testSetCenterednessMarginPermissioned() public {
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testOutOfRangeBeforeSetCenterednessMargin() public {
        // Move the pool to the edge of the price interval, so it's out of range.
        _setPoolBalances(0, 100e18);
        ReClammPoolMock(payable(pool)).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectRevert(IReClammErrors.PoolOutsideTargetRange.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(newCenterednessMargin);
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
        ReClammPoolMock(payable(pool)).setLastTimestamp(block.timestamp);

        // Exactly at boundary is still in range.
        assertTrue(IReClammPool(pool).isPoolWithinTargetRange(), "Pool is out of range");
        (uint256 centeredness, ) = IReClammPool(pool).computeCurrentPoolCenteredness();

        assertApproxEqRel(
            centeredness,
            _DEFAULT_CENTEREDNESS_MARGIN,
            1e16,
            "Pool centeredness is not close from margin"
        );

        // Margin will make the pool be out of range (since the current centeredness is near the default margin).
        vm.prank(admin);
        vm.expectRevert(IReClammErrors.PoolOutsideTargetRange.selector);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testIsPoolInTargetRange() public {
        (, , , uint256[] memory balancesScaled18) = vault.getPoolTokenInfo(pool);
        (uint256 lastVirtualBalanceA, uint256 lastVirtualBalanceB) = IReClammPool(pool).getLastVirtualBalances();
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = IReClammPool(pool).computeCurrentVirtualBalances();
        uint256 centerednessMargin = IReClammPool(pool).getCenterednessMargin();

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

        assertTrue(IReClammPool(pool).isPoolWithinTargetRange(), "Actual value not in range");

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

        ReClammPoolMock(payable(pool)).setLastVirtualBalances(newLastVirtualBalances);

        assertFalse(IReClammPool(pool).isPoolWithinTargetRange(), "Actual value still in range");

        // Must advance time, or it will return the last virtual balances. If the calculation used the last virtual
        // balances, it would return false (per calculation above).
        //
        // Since it is using the current price ratio, it should return false and the virtual balances should be
        // updated.
        vm.warp(block.timestamp + 100);
        (bool resultWithAlternateGetter, bool virtualBalancesChanged) = IReClammPool(pool)
            .isPoolWithinTargetRangeUsingCurrentVirtualBalances();

        assertFalse(resultWithAlternateGetter, "Actual value still in range with alternate getter");
        assertTrue(virtualBalancesChanged, "Last != current virtual balances");
    }

    function testInRangeUpdatingVirtualBalancesSetCenterednessMargin() public {
        vm.prank(admin);
        // Start updating virtual balances.
        ReClammPool(payable(pool)).startPriceRatioUpdate(2e18, block.timestamp, block.timestamp + 3 days);

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
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit(address(pool));
        emit IReClammEvents.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "CenterednessMarginUpdated", abi.encode(_NEW_CENTEREDNESS_MARGIN));

        vm.prank(admin);
        ReClammPool(payable(pool)).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);

        assertEq(IReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

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
        IReClammPool(pool).getReClammPoolDynamicData();
    }

    function testComputePriceRangeBeforeInitialized() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        (uint256 minPrice, uint256 maxPrice) = IReClammPool(pool).computeCurrentPriceRange();
        assertEq(minPrice, _DEFAULT_MIN_PRICE);
        assertEq(maxPrice, _DEFAULT_MAX_PRICE);
    }

    function testComputePriceRangeAfterInitialized() public view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is initialized");
        assertFalse(vault.isUnlocked(), "Vault is unlocked");

        // Should still be the initial values as nothing has changed.
        (uint256 minPrice, uint256 maxPrice) = IReClammPool(pool).computeCurrentPriceRange();
        assertApproxEqRel(minPrice, _DEFAULT_MIN_PRICE, 0.01e16, "Incorrect min price");
        assertApproxEqRel(maxPrice, _DEFAULT_MAX_PRICE, 0.01e16, "Incorrect max price");
    }

    function testCreateWithInvalidMinPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 0,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        new ReClammPool(params, vault, IReClammPoolExtension(address(0)), address(0));
    }

    function testCreateWithTargetUnderMinPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1750e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        new ReClammPool(params, vault, IReClammPoolExtension(address(0)), address(0));
    }

    function testCreateWithInvalidMaxPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 0,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        new ReClammPool(params, vault, IReClammPoolExtension(address(0)), address(0));
    }

    function testCreateWithTargetOverMaxPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 3500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        new ReClammPool(params, vault, IReClammPoolExtension(address(0)), address(0));
    }

    function testCreateWithInvalidTargetPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 0,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        new ReClammPool(params, vault, IReClammPoolExtension(address(0)), address(0));
    }

    function testOnBeforeInitializeEvents() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        ReClammPoolImmutableData memory data = IReClammPool(newPool).getReClammPoolImmutableData();

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
        emit IReClammEvents.PriceRatioStateUpdated(
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
        emit IReClammEvents.DailyPriceShiftExponentUpdated(actualDailyPriceShiftExponent, dailyPriceShiftBase);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "DailyPriceShiftExponentUpdated",
            abi.encode(actualDailyPriceShiftExponent, dailyPriceShiftBase)
        );

        vm.expectEmit(newPool);
        emit IReClammEvents.CenterednessMarginUpdated(data.initialCenterednessMargin);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "CenterednessMarginUpdated",
            abi.encode(data.initialCenterednessMargin)
        );

        vm.expectEmit(newPool);
        emit IReClammEvents.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(newPool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.prank(alice);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));
    }

    function testSetDailyPriceShiftExponentTooHigh() public {
        ReClammPoolImmutableData memory data = IReClammPool(pool).getReClammPoolImmutableData();

        uint256 newDailyPriceShiftExponent = data.maxDailyPriceShiftExponent + 1;

        vm.prank(admin);
        vm.expectRevert(IReClammErrors.DailyPriceShiftExponentTooHigh.selector);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetLastVirtualBalances() public {
        uint256 virtualBalanceA = 10000e18;
        uint256 virtualBalanceB = 12000e18;

        vm.expectEmit(pool);
        emit IReClammEvents.VirtualBalancesUpdated(virtualBalanceA, virtualBalanceB);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "VirtualBalancesUpdated", abi.encode(virtualBalanceA, virtualBalanceB));

        ReClammPoolMock(payable(pool)).setLastVirtualBalances([virtualBalanceA, virtualBalanceB].toMemoryArray());
        uint256[] memory lastVirtualBalances = _getLastVirtualBalances(pool);

        assertEq(lastVirtualBalances[a], virtualBalanceA, "Invalid last virtual balance A");
        assertEq(lastVirtualBalances[b], virtualBalanceB, "Invalid last virtual balance B");
    }

    function testSetLastVirtualBalances__Fuzz(uint256 virtualBalanceA, uint256 virtualBalanceB) public {
        virtualBalanceA = bound(virtualBalanceA, 1, type(uint128).max);
        virtualBalanceB = bound(virtualBalanceB, 1, type(uint128).max);

        ReClammPoolMock(payable(pool)).setLastVirtualBalances([virtualBalanceA, virtualBalanceB].toMemoryArray());
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

        vm.expectRevert(IReClammErrors.BalanceRatioExceedsTolerance.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, highRatioAmounts, 0, false, bytes(""));

        vm.revertToState(snapshotId);

        uint256[] memory lowRatioAmounts = _initialBalances;
        lowRatioAmounts[b] = 1e18;

        vm.expectRevert(IReClammErrors.BalanceRatioExceedsTolerance.selector);
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
            address(0), // hook contract
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
            address(0), // hook contract
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
        vm.expectRevert(IReClammErrors.InvalidStartTime.selector);
        ReClammPoolMock(payable(pool)).manualStartPriceRatioUpdate(
            data.endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        priceRatioUpdateEndTime = block.timestamp + 100; // valid

        // Fail `priceRatioUpdateStartTime < block.timestamp`.
        vm.warp(priceRatioUpdateStartTime + 1);

        vm.expectRevert(IReClammErrors.InvalidStartTime.selector);
        ReClammPoolMock(payable(pool)).manualStartPriceRatioUpdate(
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
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(exponent);

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

        (uint256 minPriceBefore, uint256 maxPriceBefore) = IReClammPool(pool).computeCurrentPriceRange();

        skip(1 days);

        (uint256 minPriceAfter, uint256 maxPriceAfter) = IReClammPool(pool).computeCurrentPriceRange();

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
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(exponent);

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
        (uint256 minPriceBefore, uint256 maxPriceBefore) = IReClammPool(pool).computeCurrentPriceRange();

        // 4. Advance time by 1 day
        skip(1 days);

        // 5. Check that the new min price is minPriceBefore * 2^exponent
        (uint256 minPriceAfter, uint256 maxPriceAfter) = IReClammPool(pool).computeCurrentPriceRange();

        // Calculate expected min price after 1 day
        // The price should move by a factor of 2^exponent (using exp2 from FixedPoint)
        uint256 expectedMinPrice = minPriceBefore.divDown(uint256(2e18).powDown(exponent));
        uint256 expectedMaxPrice = maxPriceBefore.divDown(uint256(2e18).powDown(exponent));

        // Allow for some rounding error
        assertApproxEqRel(minPriceAfter, expectedMinPrice, 1e14, "Min price did not move as expected");
        assertApproxEqRel(maxPriceAfter, expectedMaxPrice, 1e14, "Max price did not move as expected");
    }

    function testPriceRangeShiftStop__Fuzz(uint256 margin, uint256 priceShiftExponent, uint256 longDelay) public {
        uint256 SHORT_DELAY = 5 hours;

        margin = bound(margin, 1e16, _MAX_CENTEREDNESS_MARGIN);
        priceShiftExponent = bound(priceShiftExponent, 1e16, _MAX_DAILY_PRICE_SHIFT_EXPONENT);
        longDelay = bound(longDelay, 30 days, 100 days); // will get capped

        vm.startPrank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(priceShiftExponent);
        ReClammPoolMock(payable(pool)).manualSetCenterednessMargin(margin);
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

        (uint256 poolCenterednessAfterSwap, ) = IReClammPool(pool).computeCurrentPoolCenteredness();
        assertApproxEqAbs(poolCenterednessAfterSwap, 0, 0.5e16, "Pool centeredness after swap is not close to 0%");
        assertFalse(IReClammPool(pool).isPoolWithinTargetRange(), "Pool is still within target range after swap");

        // Wait some time, verify that the price is moving.
        skip(SHORT_DELAY);

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = IReClammPool(pool)
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

        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = IReClammPool(pool).computeCurrentVirtualBalances();
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
        (uint256 finalVirtualBalanceA, uint256 finalVirtualBalanceB, ) = IReClammPool(pool)
            .computeCurrentVirtualBalances();
        assertEq(finalVirtualBalanceA, currentVirtualBalanceA, "Final virtual balance A changed");
        assertEq(finalVirtualBalanceB, currentVirtualBalanceB, "Final virtual balance B changed");
    }

    function testPriceRangeShiftStopAt100__Fuzz(uint256 margin) public {
        margin = bound(margin, 1e16, _MAX_CENTEREDNESS_MARGIN);

        vm.startPrank(admin);
        ReClammPool(payable(pool)).setDailyPriceShiftExponent(100e16);
        ReClammPoolMock(payable(pool)).manualSetCenterednessMargin(margin);
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

        (uint256 poolCenterednessAfterSwap, ) = IReClammPool(pool).computeCurrentPoolCenteredness();
        assertApproxEqAbs(poolCenterednessAfterSwap, 0, 0.5e16, "Pool centeredness after swap is not close to 0%");
        assertFalse(IReClammPool(pool).isPoolWithinTargetRange(), "Pool is still within target range after swap");

        // We're way past the margin right now, but we should not go past 100%.
        skip(30 days);

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = IReClammPool(pool)
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
        (uint256 finalVirtualBalanceA, uint256 finalVirtualBalanceB, ) = IReClammPool(pool)
            .computeCurrentVirtualBalances();
        assertEq(finalVirtualBalanceA, currentVirtualBalanceA, "Final virtual balance A changed");
        assertEq(finalVirtualBalanceB, currentVirtualBalanceB, "Final virtual balance B changed");
    }

    function testWrongDeployment() public {
        IReClammPoolMain badPool = IReClammPoolMain(address(0xdeadbeef));
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            dailyPriceShiftExponent: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        ReClammPoolExtension badExtension = new ReClammPoolExtension(badPool, vault, params, address(0));

        vm.expectRevert(ReClammPool.WrongReClammPoolExtensionDeployment.selector);
        new ReClammPool(params, vault, badExtension, address(0));
    }

    function testInvariantRatios() public view {
        assertEq(IReClammPool(pool).getMinimumInvariantRatio(), 0, "Wrong minimum invariant ratio");
        assertEq(IReClammPool(pool).getMaximumInvariantRatio(), 0, "Wrong maximum invariant ratio");
    }

    function testProxyWiring() public view {
        address extension = IReClammPool(pool).getReClammPoolExtension();
        assertEq(
            address(IReClammPoolExtension(extension).pool()),
            pool,
            "Pool and extension do not point to each other"
        );
    }

    function testEthTransferPool() public {
        vm.prank(alice);
        vm.expectRevert(IVaultErrors.CannotReceiveEth.selector);
        payable(pool).transfer(1);
    }

    function testEthTransferExtension() public {
        address extension = IReClammPool(pool).getReClammPoolExtension();

        vm.prank(alice);
        vm.expectRevert(IVaultErrors.CannotReceiveEth.selector);
        payable(extension).transfer(1);
    }

    function testEthFallbackPool() public {
        vm.prank(alice);
        (bool success, bytes memory data) = pool.call{ value: 1 }(hex"deadbeef");

        assertFalse(success);
        assertEq(bytes4(data), IVaultErrors.CannotReceiveEth.selector);
    }

    function testEthFallbackPoolNoEth() public {
        vm.prank(alice);
        (bool success, bytes memory data) = pool.call(hex"deadbeef");

        assertFalse(success);
        assertEq(bytes4(data), ReClammCommon.NotImplemented.selector);
    }

    function testEthFallbackExtensionWithEth() public {
        address extension = IReClammPool(pool).getReClammPoolExtension();

        vm.prank(alice);
        (bool success, bytes memory data) = extension.call{ value: 1 }(hex"deadbeef");

        assertFalse(success);
        assertEq(bytes4(data), IVaultErrors.CannotReceiveEth.selector);
    }

    function testEthFallbackExtension() public {
        address extension = IReClammPool(pool).getReClammPoolExtension();

        vm.prank(alice);
        (bool success, bytes memory data) = extension.call(hex"deadbeef");

        assertFalse(success);
        assertEq(bytes4(data), ReClammCommon.NotImplemented.selector);
    }

    function testDelegateCalls() public {
        IReClammPoolExtension extension = IReClammPoolExtension(IReClammPool(pool).getReClammPoolExtension());

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getLastTimestamp();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getLastVirtualBalances();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getCenterednessMargin();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getDailyPriceShiftExponent();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getDailyPriceShiftBase();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getPriceRatioState();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getReClammPoolDynamicData();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.getReClammPoolImmutableData();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentPriceRatio();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentFourthRootPriceRatio();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentPriceRange();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentPoolCenteredness();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentVirtualBalances();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.computeCurrentSpotPrice();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.isPoolWithinTargetRangeUsingCurrentVirtualBalances();

        vm.expectRevert(ReClammPoolExtension.NotPoolDelegateCall.selector);
        extension.isPoolWithinTargetRangeUsingCurrentVirtualBalances();
    }

    function testVaultCalls() public {
        // Call through pool - fallback delegates to extension; onlyVault still checks msg.sender
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterInitialize(new uint256[](2), 0, bytes(""));

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterAddLiquidity(
            alice,
            pool,
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            new uint256[](2),
            1e18,
            new uint256[](2),
            bytes("")
        );

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterRemoveLiquidity(
            alice,
            pool,
            RemoveLiquidityKind.PROPORTIONAL,
            1e18,
            new uint256[](2),
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );

        PoolSwapParams memory beforeParams;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onBeforeSwap(beforeParams, pool);

        AfterSwapParams memory afterParams;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        IHooks(pool).onAfterSwap(afterParams);
    }

    function testHookCalls() public {
        pool = _createStandardPool("NoHook");

        // Call through pool with no hook contract - should revert NotImplemented
        // Need to prank as vault to pass onlyVault, then hits onlyWithHookContract
        vm.startPrank(address(vault));

        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onAfterInitialize(new uint256[](2), 0, bytes(""));

        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onAfterAddLiquidity(
            alice,
            pool,
            AddLiquidityKind.PROPORTIONAL,
            new uint256[](2),
            new uint256[](2),
            1e18,
            new uint256[](2),
            bytes("")
        );

        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onAfterRemoveLiquidity(
            alice,
            pool,
            RemoveLiquidityKind.PROPORTIONAL,
            1e18,
            new uint256[](2),
            new uint256[](2),
            new uint256[](2),
            bytes("")
        );

        PoolSwapParams memory beforeParams;
        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onBeforeSwap(beforeParams, pool);

        AfterSwapParams memory afterParams;
        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onAfterSwap(afterParams);

        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        IHooks(pool).onComputeDynamicSwapFeePercentage(beforeParams, pool, 1e16);

        vm.stopPrank();
    }

    function testInitializationPrice() public {
        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        address[] memory tokens = [address(usdc), address(dai)].toMemoryArray();
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());
        PoolRoleAccounts memory roleAccounts;

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialMinPrice - 1, // bad target price
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens);

        vm.expectRevert(IReClammErrors.InvalidInitialPrice.selector);
        ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
    }

    function _createStandardPool(string memory label) internal returns (address newPool) {
        string memory name = "ReClamm Pool";
        string memory symbol = "RECLAMM_POOL";

        address[] memory tokens = [address(usdc), address(dai)].toMemoryArray();
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());
        PoolRoleAccounts memory roleAccounts;

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: false,
            tokenBPriceIncludesRate: false
        });

        newPool = ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            vault.buildTokenConfig(sortedTokens),
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
        vm.label(newPool, label);
    }
}
