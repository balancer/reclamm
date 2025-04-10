// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import {
    AddLiquidityKind,
    PoolSwapParams,
    RemoveLiquidityKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { PriceRatioState, ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import {
    IReClammPool,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData
} from "../../contracts/interfaces/IReClammPool.sol";

contract ReClammPoolTest is BaseReClammTest {
    using CastingHelpers for IERC20[];
    using ArrayHelpers for *;
    using FixedPoint for uint256;
    using SafeCast for *;

    uint256 private constant _NEW_CENTEREDNESS_MARGIN = 30e16;

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

    function testcomputeCurrentFourthRootPriceRatio() public view {
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
        uint256 expectedPriceShiftDailyRateInSeconds = ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);
        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(priceShiftDailyRate);

        uint256 actualPriceShiftDailyRateInSeconds = ReClammPool(pool).getPriceShiftDailyRateInSeconds();
        assertEq(
            actualPriceShiftDailyRateInSeconds,
            expectedPriceShiftDailyRateInSeconds,
            "Invalid priceShiftDailyRangeInSeconds"
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

        (uint256[] memory currentVirtualBalances, ) = ReClammPool(pool).computeCurrentVirtualBalances();

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

        uint96 currentFourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
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
        assertEq(data.priceShiftDailyRangeInSeconds, newPriceShiftDailyRate / 124649, "Invalid time constant");
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
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            block.timestamp,
            priceRatioUpdateEndTime
        );
        uint256 actualPriceRatioUpdateStartTime = ReClammPool(pool).setPriceRatioState(
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );
        assertEq(actualPriceRatioUpdateStartTime, block.timestamp, "Invalid updated actual price ratio start time");

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio().toUint96();
        uint96 mathFourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
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

    function testSetPriceShiftDailyRatePoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRate() public {
        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceShiftDailyRateUpdated(
            newPriceShiftDailyRate,
            ReClammMath.computePriceShiftDailyRate(newPriceShiftDailyRate)
        );
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
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
        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        uint256[] memory lastVirtualBalancesBeforeSet = ReClammPoolMock(pool).getLastVirtualBalances();

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
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceShiftDailyRateUpdated(
            newPriceShiftDailyRate,
            ReClammMath.computePriceShiftDailyRate(newPriceShiftDailyRate)
        );
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();

        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balances do not match");
    }

    function testSetCenterednessMarginPoolNotInitialized() public {
        vault.manualSetInitializedPool(pool, false);

        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolNotInitialized.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testSetCenterednessMargin() public {
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
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
        vm.expectRevert(IReClammPool.PoolIsOutOfRange.selector);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
    }

    function testOutOfRangeAfterSetCenterednessMargin() public {
        // Move the pool close to the current margin.
        (uint256[] memory virtualBalances, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        uint256 newBalanceB = 100e18;

        // Pool Centeredness = Ra * Vb / (Rb * Va). Make centeredness = margin, and you have the equation below.
        uint256 newBalanceA = (_DEFAULT_CENTEREDNESS_MARGIN * newBalanceB).mulDown(virtualBalances[0]) /
            virtualBalances[1];
        _setPoolBalances(newBalanceA, newBalanceB);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        assertTrue(ReClammPoolMock(pool).isPoolInRange(), "Pool is out of range");
        assertApproxEqRel(
            ReClammPoolMock(pool).computeCurrentPoolCenteredness(),
            _DEFAULT_CENTEREDNESS_MARGIN,
            1e16,
            "Pool centeredness is not close from margin"
        );

        // Margin will make the pool be out of range (since the current centeredness is near the default margin).
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolIsOutOfRange.selector);
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);
    }

    function testInRangeUpdatingVirtualBalancesSetCenterednessMargin() public {
        vm.prank(admin);
        // Start updating virtual balances.
        ReClammPool(pool).setPriceRatioState(2e18, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        // Check if the last virtual balances stored in the pool are different from the current virtual balances.
        (uint256[] memory virtualBalancesBefore, ) = ReClammPool(pool).computeCurrentVirtualBalances();
        uint256[] memory lastVirtualBalancesBeforeSet = ReClammPoolMock(pool).getLastVirtualBalances();

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

        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(_NEW_CENTEREDNESS_MARGIN);
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
        ReClammPool(pool).setCenterednessMargin(_NEW_CENTEREDNESS_MARGIN);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balance does not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balance does not match");
    }

    function testComputePriceRangeBeforeInitialized() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[0]), address(sortedTokens[1])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        assertEq(minPrice, _DEFAULT_MIN_PRICE);
        assertEq(maxPrice, _DEFAULT_MAX_PRICE);
    }

    function testComputePriceRangeAfterInitialized() public view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is initialized");

        // Should still be the initial values as nothing has changed.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        assertApproxEqAbs(minPrice, _DEFAULT_MIN_PRICE, 2e6);
        assertApproxEqAbs(maxPrice, _DEFAULT_MAX_PRICE, 2e6);
    }
}
