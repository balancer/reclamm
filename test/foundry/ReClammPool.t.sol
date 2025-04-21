// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

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
    RemoveLiquidityKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { PriceRatioState, ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
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
    using CastingHelpers for IERC20[];
    using FixedPoint for uint256;
    using ArrayHelpers for *;
    using SafeCast for *;

    uint256 private constant _NEW_CENTEREDNESS_MARGIN = 30e16;
    uint256 private constant _INITIAL_AMOUNT = 1000e18;

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
        ReClammPool(pool).setPriceShiftDailyRate(20e16);

        uint256 lastTimestampBeforeWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampBeforeWarp, block.timestamp, "Invalid lastTimestamp before warp");

        skip(1 hours);
        uint256 lastTimestampAfterWarp = ReClammPool(pool).getLastTimestamp();
        assertEq(lastTimestampAfterWarp, lastTimestampBeforeWarp, "Invalid lastTimestamp after warp");

        // Call any function that updates the last timestamp.
        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(30e16);

        uint256 lastTimestampAfterSetPriceShiftDailyRate = ReClammPool(pool).getLastTimestamp();
        assertEq(
            lastTimestampAfterSetPriceShiftDailyRate,
            block.timestamp,
            "Invalid lastTimestamp after setPriceShiftDailyRate"
        );
    }

    function testGetPriceShiftDailyRateInSeconds() public {
        uint256 priceShiftDailyRate = 20e16;
        uint256 expectedPriceShiftDailyRateInSeconds = mathMock.computePriceShiftDailyRate(priceShiftDailyRate);
        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(priceShiftDailyRate);

        uint256 actualPriceShiftDailyRateInSeconds = ReClammPool(pool).getPriceShiftDailyRateInSeconds();
        assertEq(
            actualPriceShiftDailyRateInSeconds,
            expectedPriceShiftDailyRateInSeconds,
            "Invalid priceShiftDailyRateInSeconds"
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
        uint256 newPriceShiftDailyRate = 200e16;
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
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
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
        assertEq(data.priceShiftDailyRateInSeconds, newPriceShiftDailyRate / 124649, "Invalid price shift daily rate");
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

        assertEq(data.minCenterednessMargin, 0, "Invalid min centeredness margin");
        assertEq(data.maxCenterednessMargin, FixedPoint.ONE, "Invalid max centeredness margin");

        // Ensure that centeredness margin parameters fit in uint64
        assertEq(data.minCenterednessMargin, uint64(data.minCenterednessMargin), "Min centeredness margin not uint64");
        assertEq(data.maxCenterednessMargin, uint64(data.maxCenterednessMargin), "Max centeredness margin not uint64");

        assertEq(data.minTokenBalanceScaled18, _MIN_TOKEN_BALANCE, "Invalid min token balance");
        assertEq(data.minPoolCenteredness, _MIN_POOL_CENTEREDNESS, "Invalid min pool centeredness");
        assertEq(data.maxPriceShiftDailyRate, 500e16, "Invalid max price shift daily rate");
        assertEq(data.minPriceRatioUpdateDuration, 6 hours, "Invalid min price ratio update duration");
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

    function testGetRate() public {
        vm.expectRevert(IReClammPool.ReClammPoolBptRateUnsupported.selector);
        ReClammPool(pool).getRate();
    }

    function testComputeBalance() public {
        vm.expectRevert(IReClammPool.NotImplemented.selector);
        ReClammPool(pool).computeBalance(new uint256[](0), 0, 0);
    }

    function testSetPriceShiftDailyRateVaultUnlocked() public {
        vault.forceUnlock();

        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.VaultIsNotLocked.selector);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRatePoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRate() public {
        uint256 newPriceShiftDailyRate = 200e16;

        uint256 rateInSeconds = ReClammMath.computePriceShiftDailyRate(newPriceShiftDailyRate);

        vm.expectEmit();
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit();
        emit IReClammPool.PriceShiftDailyRateUpdated(newPriceShiftDailyRate, rateInSeconds);

        vm.expectEmit();
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceShiftDailyRateUpdated",
            abi.encode(newPriceShiftDailyRate, rateInSeconds)
        );

        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRatePermissioned() public {
        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRateUpdatingVirtualBalance() public {
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

        uint256 newPriceShiftDailyRate = 200e16;
        uint128 dailyRateInSeconds = ReClammMath.computePriceShiftDailyRate(newPriceShiftDailyRate);

        vm.expectEmit(address(pool));
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(pool, "LastTimestampUpdated", abi.encode(block.timestamp.toUint32()));

        vm.expectEmit(address(pool));
        emit IReClammPool.PriceShiftDailyRateUpdated(
            newPriceShiftDailyRate,
            ReClammMath.computePriceShiftDailyRate(newPriceShiftDailyRate)
        );

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            pool,
            "PriceShiftDailyRateUpdated",
            abi.encode(newPriceShiftDailyRate, dailyRateInSeconds)
        );

        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);

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

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatio();

        uint256[] memory initialBalances = ReClammPool(pool).computeInitialBalances(sortedTokens[a], _INITIAL_AMOUNT);
        assertEq(initialBalances[a], _INITIAL_AMOUNT, "Invalid initial balance for token A");
        assertEq(
            initialBalances[b],
            _INITIAL_AMOUNT.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalances, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesTokenB() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatio();

        uint256[] memory initialBalances = ReClammPool(pool).computeInitialBalances(sortedTokens[b], _INITIAL_AMOUNT);
        assertEq(initialBalances[b], _INITIAL_AMOUNT, "Invalid initial balance for token B");
        assertEq(
            initialBalances[a],
            _INITIAL_AMOUNT.divDown(initialBalanceRatio),
            "Invalid initial balance for token A"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalances, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    function testComputeInitialBalancesInvalidToken() public {
        vm.expectRevert(IVaultErrors.InvalidToken.selector);
        ReClammPool(pool).computeInitialBalances(wsteth, _INITIAL_AMOUNT);
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
            priceShiftDailyRate: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 0,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 1500e18
        });

        vm.expectRevert(IReClammPool.InvalidInitialPrice.selector);
        new ReClammPool(params, vault);
    }

    function testCreateWithInvalidTargetPrice() public {
        ReClammPoolParams memory params = ReClammPoolParams({
            name: "ReClamm Pool",
            symbol: "FAIL_POOL",
            version: "1",
            priceShiftDailyRate: 1e18,
            centerednessMargin: 0.2e18,
            initialMinPrice: 1000e18,
            initialMaxPrice: 2000e18,
            initialTargetPrice: 0
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

        uint128 dailyRateInSeconds = ReClammMath.computePriceShiftDailyRate(data.initialPriceShiftDailyRate);

        vm.expectEmit(newPool);
        emit IReClammPool.PriceRatioStateUpdated(0, fourthRootPriceRatio, block.timestamp, block.timestamp);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "PriceRatioStateUpdated",
            abi.encode(0, fourthRootPriceRatio, block.timestamp, block.timestamp)
        );

        vm.expectEmit(newPool);
        emit IReClammPool.PriceShiftDailyRateUpdated(data.initialPriceShiftDailyRate, dailyRateInSeconds);

        vm.expectEmit(address(vault));
        emit IVaultEvents.VaultAuxiliary(
            newPool,
            "PriceShiftDailyRateUpdated",
            abi.encode(data.initialPriceShiftDailyRate, dailyRateInSeconds)
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

    function testSetPriceShiftDailyRateTooHigh() public {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        uint256 newPriceShiftDailyRate = data.maxPriceShiftDailyRate + 1;

        vm.prank(admin);
        vm.expectRevert(IReClammPool.PriceShiftDailyRateTooHigh.selector);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
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

        assertEq(ReClammPool(pool).computeInitialBalanceRatio(), bOverA, "Wrong initial balance ratio");

        IERC20[] memory tokens = vault.getPoolTokens(pool);

        // Compute balances given A.
        uint256[] memory initialBalances = ReClammPool(pool).computeInitialBalances(tokens[a], _INITIAL_AMOUNT);
        assertEq(initialBalances[a], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (A)");
        uint256 expectedAmount = _INITIAL_AMOUNT.mulDown(bOverA);
        assertEq(initialBalances[b], expectedAmount, "Wrong other token amount (B)");

        // Compute balances given B.
        initialBalances = ReClammPool(pool).computeInitialBalances(tokens[b], _INITIAL_AMOUNT);
        assertEq(initialBalances[b], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (B)");
        expectedAmount = _INITIAL_AMOUNT.divDown(bOverA);
        assertEq(initialBalances[a], expectedAmount, "Wrong other token amount (A)");
    }
}
