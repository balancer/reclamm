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
import {
    AddLiquidityKind,
    PoolSwapParams,
    RemoveLiquidityKind,
    PoolRoleAccounts
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { PriceRatioState, ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactoryMock } from "../../contracts/test/ReClammPoolFactoryMock.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import {
    IReClammPool,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData,
    ReClammPoolParams
} from "../../contracts/interfaces/IReClammPool.sol";

contract ReClammPoolTest is BaseReClammTest {
    using FixedPoint for uint256;
    using CastingHelpers for *;
    using ArrayHelpers for *;
    using SafeCast for *;

    uint256 private constant _NEW_CENTEREDNESS_MARGIN = 30e16;
    uint256 private constant _INITIAL_AMOUNT = 1000e18;

    uint256 private constant _INITIAL_PARAMS_ERROR = 1e6;
    // Tokens with decimals introduces some rounding imprecisions, so we need to be more tolerant with the inverse
    // initialization error.
    uint256 private constant _INVERSE_INITIALIZATION_ERROR = 1e12;

    ReClammMathMock mathMock = new ReClammMathMock();

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
            address(this),
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
            address(this),
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
        ReClammPool(pool).setDailyPriceShiftExponent(20e16);

        uint256 lastTimestampBeforeWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampBeforeWarp, block.timestamp, "Invalid lastTimestamp before warp");

        skip(1 hours);
        uint256 lastTimestampAfterWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampAfterWarp, lastTimestampBeforeWarp, "Invalid lastTimestamp after warp");

        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(pool).setDailyPriceShiftExponent(30e16);

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
        uint256 dailyPriceRateExponent = 30e16;
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
        assertEq(priceRatioState.startFourthRootPriceRatio, 0, "Invalid default startFourthRootPriceRatio");
        assertEq(
            priceRatioState.endFourthRootPriceRatio,
            _initialFourthRootPriceRatio,
            "Invalid default endFourthRootPriceRatio"
        );
        assertEq(
            priceRatioState.priceRatioUpdateStartTime,
            block.timestamp,
            "Invalid default priceRatioUpdateStartTime"
        );
        assertEq(priceRatioState.priceRatioUpdateEndTime, block.timestamp, "Invalid default priceRatioUpdateEndTime");

        uint256 oldFourthRootPriceRatio = priceRatioState.endFourthRootPriceRatio;
        uint256 newFourthRootPriceRatio = 5e18;
        uint256 newPriceRatioUpdateStartTime = block.timestamp;
        uint256 newPriceRatioUpdateEndTime = block.timestamp + 6 hours;
        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(
            newFourthRootPriceRatio,
            newPriceRatioUpdateStartTime,
            newPriceRatioUpdateEndTime
        );

        priceRatioState = ReClammPool(pool).getPriceRatioState();
        assertEq(
            priceRatioState.startFourthRootPriceRatio,
            oldFourthRootPriceRatio,
            "Invalid new startFourthRootPriceRatio"
        );
        assertEq(
            priceRatioState.endFourthRootPriceRatio,
            newFourthRootPriceRatio,
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
        uint256 newDailyPriceShiftExponent = 200e16;
        uint256 endFourthRootPriceRatio = 8e18;
        uint256 newStaticSwapFeePercentage = 5e16;

        PriceRatioState memory state = PriceRatioState({
            startFourthRootPriceRatio: ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96(),
            endFourthRootPriceRatio: endFourthRootPriceRatio.toUint96(),
            priceRatioUpdateStartTime: block.timestamp.toUint32(),
            priceRatioUpdateEndTime: (block.timestamp + 1 days).toUint32()
        });

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(pool);

        vm.startPrank(admin);
        ReClammPool(pool).setPriceRatioState(
            state.endFourthRootPriceRatio,
            state.priceRatioUpdateStartTime,
            state.priceRatioUpdateEndTime
        );
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
        vault.setStaticSwapFeePercentage(pool, newStaticSwapFeePercentage);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours);

        uint96 currentFourthRootPriceRatio = mathMock.computeFourthRootPriceRatio(
            block.timestamp.toUint32(),
            state.startFourthRootPriceRatio,
            state.endFourthRootPriceRatio,
            state.priceRatioUpdateStartTime,
            state.priceRatioUpdateEndTime
        );

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
        assertEq(data.tokens.length, 2, "Invalid number of tokens");
        assertEq(data.decimalScalingFactors.length, 2, "Invalid number of decimal scaling factors");

        assertEq(address(data.tokens[daiIdx]), address(dai), "Invalid DAI token");
        assertEq(address(data.tokens[usdcIdx]), address(usdc), "Invalid USDC token");

        // Tokens with 18 decimals do not scale, so the scaling factor is 1.
        assertEq(data.decimalScalingFactors[daiIdx], 1, "Invalid DAI decimal scaling factor");
        assertEq(data.decimalScalingFactors[usdcIdx], 1, "Invalid USDC decimal scaling factor");

        assertFalse(data.tokenAPriceIncludesRate, "Token A priced with rate");
        assertFalse(data.tokenBPriceIncludesRate, "Token B priced with rate");

        assertEq(data.maxCenterednessMargin, 50e16, "Invalid max centeredness margin");

        // Ensure that the max centeredness margin parameter fits in uint64.
        assertEq(data.maxCenterednessMargin, uint64(data.maxCenterednessMargin), "Max centeredness margin not uint64");

        assertEq(data.minTokenBalanceScaled18, _MIN_TOKEN_BALANCE, "Invalid min token balance");
        assertEq(data.minPoolCenteredness, _MIN_POOL_CENTEREDNESS, "Invalid min pool centeredness");
        assertEq(
            data.maxDailyPriceShiftExponent,
            _MAX_DAILY_PRICE_SHIFT_EXPONENT,
            "Invalid max daily price shift exponent"
        );
        assertEq(data.minPriceRatioUpdateDuration, 6 hours, "Invalid min price ratio update duration");
    }

    function testSetFourthRootPriceRatioPermissioned() public {
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        vm.prank(alice);
        ReClammPool(pool).setPriceRatioState(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(1, block.timestamp, block.timestamp);
    }

    function testSetFourthRootPriceRatioShortDuration() public {
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 6 hours;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(IReClammPool.PriceRatioUpdateDurationTooShort.selector);
        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testSetFourthRootPriceRatioSmallDelta() public {
        uint256 delta = _MIN_FOURTH_ROOT_PRICE_RATIO_DELTA - 1;
        uint96 startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        uint96 endFourthRootPriceRatio = startFourthRootPriceRatio + delta.toUint96();
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp);
        uint32 duration = 6 hours;
        uint32 priceRatioUpdateEndTime = priceRatioUpdateStartTime + duration;

        vm.expectRevert(abi.encodeWithSelector(IReClammPool.FourthRootPriceRatioDeltaBelowMin.selector, delta));
        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testSetFourthRootPriceRatio() public {
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 6 hours;
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
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
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

        assertEq(fourthRootPriceRatio, mathFourthRootPriceRatio, "FourthRootPriceRatio not updated correctly");

        skip(duration / 2 + 1);
        fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(fourthRootPriceRatio, endFourthRootPriceRatio, "FourthRootPriceRatio does not match new value");
    }

    /// @dev Trigger a price ratio update while another one is ongoing.
    function testSetFourthRootPriceRatioOverride() public {
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 24 hours;
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
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
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

        assertEq(fourthRootPriceRatio, mathFourthRootPriceRatio, "FourthRootPriceRatio not updated correctly");

        // While the update is ongoing, we'll trigger a second one.
        // This one will update virtual balances too.
        endFourthRootPriceRatio = 4e18;
        timeOffset = 1 hours;
        priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        duration = 6 hours;
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
        actualPriceRatioUpdateStartTime = ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        vm.warp(priceRatioUpdateEndTime + 1);
        fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        assertEq(fourthRootPriceRatio, endFourthRootPriceRatio, "FourthRootPriceRatio does not match new value");
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
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 timeOffset = 1 hours;
        uint32 priceRatioUpdateStartTime = uint32(block.timestamp) - timeOffset;
        uint32 duration = 6 hours;
        uint32 priceRatioUpdateEndTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();

        vm.prank(admin);
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
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

        assertEq(fourthRootPriceRatio, mathFourthRootPriceRatio, "FourthRootPriceRatio not updated correctly");

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

        uint256 newDailyPriceShiftExponent = 200e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.VaultIsNotLocked.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        uint256 newDailyPriceShiftExponent = 200e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponent() public {
        uint256 newDailyPriceShiftExponent = 200e16;

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
        uint256 newDailyPriceShiftExponent = 200e16;
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
    }

    function testSetDailyPriceShiftExponentUpdatingVirtualBalance() public {
        // Move the pool to the edge of the price interval, so the virtual balances will change over time.
        _setPoolBalances(_MIN_TOKEN_BALANCE, 100e18);
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
        assertNotEq(
            virtualBalancesBefore[usdcIdx],
            lastVirtualBalancesBeforeSet[usdcIdx],
            "USDC virtual balance remains unchanged"
        );

        uint256 newDailyPriceShiftExponent = 200e16;
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
        ReClammPool(pool).setCenterednessMargin(centerednessMarginAbove100);
    }

    function testSetCenterednessMarginPermissioned() public {
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testOutOfRangeBeforeSetCenterednessMargin() public {
        // Move the pool to the edge of the price interval, so it's out of range.
        _setPoolBalances(_MIN_TOKEN_BALANCE, 100e18);
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
        assertApproxEqRel(
            ReClammPoolMock(pool).computeCurrentPoolCenteredness(),
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

        // Must advance time, or it will return the last virtual balances. If the calculation used the last virtual
        // balances, it would return false (per calculation above).
        //
        // Since it is *not* using the last balances, it should still return true.
        vm.warp(block.timestamp + 100);
        (bool resultWithAlternateGetter, bool virtualBalancesChanged) = ReClammPool(pool)
            .isPoolWithinTargetRangeUsingCurrentVirtualBalances();

        assertTrue(resultWithAlternateGetter, "Actual value not in range with alternate getter");
        assertTrue(virtualBalancesChanged, "Last == current virtual balances");
    }

    function testInRangeUpdatingVirtualBalancesSetCenterednessMargin() public {
        vm.prank(admin);
        // Start updating virtual balances.
        ReClammPool(pool).setPriceRatioState(2e18, block.timestamp, block.timestamp + 1 days);

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

    function testComputeInitialBalancesTokenA() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[a])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialAmountRaw
        );

        assertEq(initialBalancesRaw[a], initialAmountRaw, "Invalid initial balance for token A");

        assertEq(
            initialBalancesRaw[b],
            initialAmountRaw.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenAWithRateA() public {
        uint256 rateA = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[a])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialAmountRaw
        );
        assertEq(initialBalancesRaw[a], initialAmountRaw, "Invalid initial balance for token A");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        assertApproxEqAbs(
            initialBalancesRaw[b],
            initialAmountRaw.mulDown(initialBalanceRatio).mulDown(rateA),
            1000,
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenAWithRateB() public {
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenBPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[a])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderB.mockRate(rateB);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialAmountRaw
        );
        assertEq(initialBalancesRaw[a], initialAmountRaw, "Invalid initial balance for token A");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        assertApproxEqAbs(
            initialBalancesRaw[b],
            initialAmountRaw.mulDown(initialBalanceRatio).divDown(rateB),
            1000,
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenAWithRateBoth() public {
        uint256 rateA = 3e18;
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[a])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialAmountRaw
        );
        assertEq(initialBalancesRaw[a], initialAmountRaw, "Invalid initial balance for token A");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        assertApproxEqAbs(
            initialBalancesRaw[b],
            initialAmountRaw.mulDown(initialBalanceRatio).mulDown(rateA).divDown(rateB),
            1000,
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenB() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmountRaw
        );
        assertEq(initialBalancesRaw[b], initialAmountRaw, "Invalid initial balance for token B");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        assertApproxEqAbs(
            initialBalancesRaw[a],
            initialAmountRaw.divDown(initialBalanceRatio),
            1000,
            "Invalid initial balance for token A"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenBWithRateA() public {
        uint256 rateA = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmountRaw
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], initialAmountRaw, "Invalid initial balance for token B");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        // The other token should be the reference / initialBalanceRatio (adjusted for the rate).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertApproxEqAbs(
            initialBalancesRaw[a],
            initialAmountRaw.divDown(initialBalanceRatio.mulDown(rateA)),
            1000,
            "Invalid initial balance for token A"
        );

        // Test "inverse" initialization.
        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            initialAmountRaw,
            _INVERSE_INITIALIZATION_ERROR,
            "Wrong inverse initialization balance (A)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    function testComputeInitialBalancesTokenBWithRateB() public {
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenBPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmountRaw
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], initialAmountRaw, "Invalid initial balance for token B");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        // The other token should be the reference / initialBalanceRatio (adjusted for the rate).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertApproxEqAbs(
            initialBalancesRaw[a],
            initialAmountRaw.mulDown(rateB).divDown(initialBalanceRatio),
            1000,
            "Invalid initial balance for token A"
        );

        // Test "inverse" initialization.
        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            initialAmountRaw,
            _INVERSE_INITIALIZATION_ERROR,
            "Wrong inverse initialization balance (B)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    function testComputeInitialBalancesTokenBWithRateBoth() public {
        uint256 rateA = 3e18;
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;

        // Avoids math overflow when decimal is a low number.
        uint256 initialAmountRaw = _INITIAL_AMOUNT / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmountRaw
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], initialAmountRaw, "Invalid initial balance for token B");

        // Allows some rounding errors due to multiplication and division by the decimal factor.
        // The other token should be the reference / initialBalanceRatio (adjusted for both rates).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertApproxEqAbs(
            initialBalancesRaw[a],
            initialAmountRaw.divDown(initialBalanceRatio).mulDown(rateB).divDown(rateA),
            1000,
            "Invalid initial balance for token A"
        );

        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            initialAmountRaw,
            _INVERSE_INITIALIZATION_ERROR,
            "Wrong inverse initialization balance (AB)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    function testComputeInitialBalances__Fuzz(
        uint256 initialAmount,
        uint256 rateA,
        uint256 rateB,
        bool tokenAWithRate,
        bool tokenBWithRate
    ) public {
        initialAmount = bound(initialAmount, 1e18, _INITIAL_AMOUNT);
        rateA = bound(rateA, 1e18, 1000e18);
        rateB = bound(rateB, 1e18, 1000e18);
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(wbtc8Decimals)].toMemoryArray().asIERC20()
        );
        _tokenAPriceIncludesRate = tokenAWithRate;
        _tokenBPriceIncludesRate = tokenBWithRate;
        initialAmount = initialAmount / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], initialAmount, "Invalid initial balance for token B");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[a],
            inverseInitialBalances[a],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (a)"
        );

        assertApproxEqRel(
            initialBalancesRaw[b],
            inverseInitialBalances[b],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (b)"
        );

        vm.assume(initialBalancesRaw[a] > 1e6);
        vm.assume(initialBalancesRaw[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshot();
        _initPool(newPool, initialBalancesRaw, 0);
        _validatePostInitConditions();
        vm.revertTo(snapshotId);

        _initPool(newPool, inverseInitialBalances, 0);
        _validatePostInitConditions();
    }

    function testComputeInitialBalancesInvalidToken() public {
        vm.expectRevert(IVaultErrors.InvalidToken.selector);
        ReClammPool(pool).computeInitialBalancesRaw(wsteth, _INITIAL_AMOUNT);
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

    function testComputePriceRangeAfterInitialized() public view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is initialized");
        assertFalse(vault.isUnlocked(), "Vault is unlocked");

        // Should still be the initial values as nothing has changed.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        assertApproxEqAbs(minPrice, _DEFAULT_MIN_PRICE, 2e6);
        assertApproxEqAbs(maxPrice, _DEFAULT_MAX_PRICE, 2e6);
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

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
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

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
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

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
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

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
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

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
    }

    function testToPoolCenterAboveEnum() public pure {
        assertEq(
            uint256(ReClammMath.toEnum(false)),
            uint256(ReClammMath.PoolAboveCenter.FALSE),
            "Invalid enum value (false)"
        );
        assertEq(
            uint256(ReClammMath.toEnum(true)),
            uint256(ReClammMath.PoolAboveCenter.TRUE),
            "Invalid enum value (true)"
        );
        assertNotEq(
            uint256(ReClammMath.toEnum(false)),
            uint256(ReClammMath.PoolAboveCenter.TRUE),
            "Invalid enum value (false/true)"
        );
        assertNotEq(
            uint256(ReClammMath.toEnum(true)),
            uint256(ReClammMath.PoolAboveCenter.FALSE),
            "Invalid enum value (true/false)"
        );
    }

    function testOnBeforeInitializeEvents() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        ReClammPoolImmutableData memory data = ReClammPool(newPool).getReClammPoolImmutableData();

        (, , , uint256 fourthRootPriceRatio) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            data.initialMinPrice,
            data.initialMaxPrice,
            data.initialTargetPrice
        );

        uint128 dailyPriceShiftBase = ReClammMath
            .toDailyPriceShiftBase(data.initialDailyPriceShiftExponent)
            .toUint128();
        uint256 actualDailyPriceShiftExponent = ReClammMath.toDailyPriceShiftExponent(dailyPriceShiftBase);

        vm.expectEmit(newPool);
        emit IReClammPool.PriceRatioStateUpdated(0, fourthRootPriceRatio, block.timestamp, block.timestamp);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "PriceRatioStateUpdated",
            abi.encode(0, fourthRootPriceRatio, block.timestamp, block.timestamp)
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
    }

    function testSetDailyPriceShiftExponentTooHigh() public {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        uint256 newDailyPriceShiftExponent = data.maxDailyPriceShiftExponent + 1;

        vm.prank(admin);
        vm.expectRevert(IReClammPool.DailyPriceShiftExponentTooHigh.selector);
        ReClammPool(pool).setDailyPriceShiftExponent(newDailyPriceShiftExponent);
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

        uint256 snapshotId = vm.snapshot();

        vm.expectRevert(IReClammPool.BalanceRatioExceedsTolerance.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, highRatioAmounts, 0, false, bytes(""));

        vm.revertTo(snapshotId);

        uint256[] memory lowRatioAmounts = _initialBalances;
        lowRatioAmounts[b] = 1e18;

        vm.expectRevert(IReClammPool.BalanceRatioExceedsTolerance.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, lowRatioAmounts, 0, false, bytes(""));
    }

    function testInitializationPriceErrors() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");

        ReClammPoolImmutableData memory data = ReClammPool(newPool).getReClammPoolImmutableData();

        (
            uint256[] memory theoreticalRealBalances,
            uint256 theoreticalVirtualBalanceA,
            uint256 theoreticalVirtualBalanceB,

        ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
                data.initialMinPrice,
                data.initialMaxPrice,
                data.initialTargetPrice
            );

        uint256[] memory realBalances = theoreticalRealBalances;
        realBalances[a] = 0;

        // Trigger on upper bound.
        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        ReClammPoolMock(newPool).checkInitializationPrices(
            realBalances,
            theoreticalVirtualBalanceA,
            theoreticalVirtualBalanceB
        );

        realBalances[a] = theoreticalRealBalances[a];
        realBalances[b] = 0;

        // Trigger on lower bound.
        vm.expectRevert(IReClammPool.WrongInitializationPrices.selector);
        ReClammPoolMock(newPool).checkInitializationPrices(
            realBalances,
            theoreticalVirtualBalanceA,
            theoreticalVirtualBalanceB
        );
    }

    function testInitializationTokenErrors() public {
        address newPool = _createStandardPool(true, false, "Price Token A");

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPool(newPool).computeInitialBalanceRatioRaw();

        newPool = _createStandardPool(false, true, "Price Token B");

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        ReClammPool(newPool).computeInitialBalanceRatioRaw();
    }

    function testInitializationCenteredness() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        ReClammPoolMock(newPool).manualSetCenterednessMargin(FixedPoint.ONE);

        vm.expectRevert(IReClammPool.PoolCenterednessTooLow.selector);
        vm.prank(alice);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));
    }

    function testInvalidStartTime() public {
        ReClammPoolDynamicData memory data = IReClammPool(pool).getReClammPoolDynamicData();

        uint256 priceRatioUpdateStartTime = block.timestamp;
        uint256 priceRatioUpdateEndTime = block.timestamp - 100; // invalid

        // Fail `priceRatioUpdateStartTime > priceRatioUpdateEndTime`.
        vm.expectRevert(IReClammPool.InvalidStartTime.selector);
        ReClammPoolMock(pool).manualSetPriceRatioState(
            data.endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        priceRatioUpdateEndTime = block.timestamp + 100; // valid

        // Fail `priceRatioUpdateStartTime < block.timestamp`.
        vm.warp(priceRatioUpdateStartTime + 1);

        vm.expectRevert(IReClammPool.InvalidStartTime.selector);
        ReClammPoolMock(pool).manualSetPriceRatioState(
            data.endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
    }

    function testInitialBalanceRatioAndBalances() public view {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        (uint256[] memory realBalances, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            data.initialMinPrice,
            data.initialMaxPrice,
            data.initialTargetPrice
        );

        uint256 bOverA = realBalances[b].divDown(realBalances[a]);
        // If the ratio is 1, this isn't testing anything.
        assertNotEq(bOverA, FixedPoint.ONE, "Ratio is 1");

        assertEq(ReClammPool(pool).computeInitialBalanceRatioRaw(), bOverA, "Wrong initial balance ratio");

        IERC20[] memory tokens = vault.getPoolTokens(pool);

        // Compute balances given A.
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(tokens[a], _INITIAL_AMOUNT);
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (A)");
        uint256 expectedAmount = _INITIAL_AMOUNT.mulDown(bOverA);
        assertEq(initialBalancesRaw[b], expectedAmount, "Wrong other token amount (B)");

        // Compute balances given B.
        initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(tokens[b], _INITIAL_AMOUNT);
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (B)");
        expectedAmount = _INITIAL_AMOUNT.divDown(bOverA);
        assertEq(initialBalancesRaw[a], expectedAmount, "Wrong other token amount (A)");
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
            balances[a] - _MIN_TOKEN_BALANCE,
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
            balances[b] - _MIN_TOKEN_BALANCE,
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

    function _validatePostInitConditions() private view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");

        // Validate price ratio and target.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        assertApproxEqRel(
            maxPrice.divDown(minPrice),
            data.initialMaxPrice.divDown(data.initialMinPrice),
            _INITIAL_PARAMS_ERROR,
            "Wrong price ratio after initialization with rate"
        );

        uint256 targetPrice = ReClammPool(pool).computeCurrentTargetPrice();
        assertApproxEqRel(
            targetPrice,
            data.initialTargetPrice,
            _INITIAL_PARAMS_ERROR,
            "Wrong target price after initialization with rate"
        );
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

        ReClammPoolFactoryMock.ReClammPriceParams memory priceParams = ReClammPoolFactoryMock.ReClammPriceParams({
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
