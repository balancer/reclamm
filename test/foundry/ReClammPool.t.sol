// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { PriceRatioState, ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract ReClammPoolTest is BaseReClammTest {
    using FixedPoint for uint256;
    using SafeCast for *;

    function testGetCurrentFourthRootPriceRatio() public view {
        uint256 fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, _DEFAULT_FOURTH_ROOT_PRICE_RATIO, "Invalid default fourthRootPriceRatio");
    }

    function testGetCenterednessMargin() public {
        uint256 centerednessMargin = ReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, _DEFAULT_CENTEREDNESS_MARGIN, "Invalid default centerednessMargin");

        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);

        centerednessMargin = ReClammPool(pool).getCenterednessMargin();
        assertEq(centerednessMargin, newCenterednessMargin, "Invalid new centerednessMargin");
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

    function testGetTimeConstant() public {
        uint256 priceShiftDailyRate = 20e16;
        uint256 expectedTimeConstant = ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);
        vm.prank(admin);
        ReClammPool(pool).setPriceShiftDailyRate(priceShiftDailyRate);

        uint256 actualTimeConstant = ReClammPool(pool).getTimeConstant();
        assertEq(actualTimeConstant, expectedTimeConstant, "Invalid timeConstant");
    }

    function testGetPriceRatioState() public {
        PriceRatioState memory priceRatioState = ReClammPool(pool).getPriceRatioState();
        assertEq(
            priceRatioState.startFourthRootPriceRatio,
            _DEFAULT_FOURTH_ROOT_PRICE_RATIO,
            "Invalid default startFourthRootPriceRatio"
        );
        assertEq(
            priceRatioState.endFourthRootPriceRatio,
            _DEFAULT_FOURTH_ROOT_PRICE_RATIO,
            "Invalid default endFourthRootPriceRatio"
        );
        assertEq(priceRatioState.startTime, 0, "Invalid default startTime");
        assertEq(priceRatioState.endTime, block.timestamp, "Invalid default endTime");

        uint256 oldFourthRootPriceRatio = priceRatioState.endFourthRootPriceRatio;
        uint256 newFourthRootPriceRatio = 5e18;
        uint256 newStartTime = block.timestamp;
        uint256 newEndTime = block.timestamp + 1 hours;
        vm.prank(admin);
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, newStartTime, newEndTime);

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
        assertEq(priceRatioState.startTime, newStartTime, "Invalid new startTime");
        assertEq(priceRatioState.endTime, newEndTime, "Invalid new endTime");
    }

    function testSetFourthRootPriceRatio() public {
        uint96 endFourthRootPriceRatio = 2e18;
        uint32 startTime = uint32(block.timestamp);
        uint32 duration = 1 hours;
        uint32 endTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );
        ReClammPool(pool).setPriceRatioState(endFourthRootPriceRatio, startTime, endTime);

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        uint96 mathFourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            uint32(block.timestamp),
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            startTime,
            endTime
        );

        assertEq(fourthRootPriceRatio, mathFourthRootPriceRatio, "FourthRootPriceRatio not updated correctly");

        skip(duration / 2 + 1);
        fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, endFourthRootPriceRatio, "FourthRootPriceRatio does not match new value");
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
        uint256[] memory virtualBalancesBefore = ReClammPool(pool).getCurrentVirtualBalances();
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

    function testSetCenterednessMargin() public {
        uint64 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(newCenterednessMargin);
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
    }

    function testSetCenterednessMarginAbove100() public {
        uint64 newCenterednessMargin = uint64(FixedPoint.ONE + 1);
        vm.prank(admin);
        vm.expectRevert(IReClammPool.InvalidCenterednessMargin.selector);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
    }

    function testSetCenterednessMarginPermissioned() public {
        uint64 newCenterednessMargin = 50e16;
        vm.prank(alice);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
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
        uint256[] memory virtualBalances = ReClammPool(pool).getCurrentVirtualBalances();
        uint256 newBalanceB = 100e18;

        // Pool Centeredness = Ra * Vb / (Rb * Va). Make centeredness = margin, and you have the equation below.
        uint256 newBalanceA = (_DEFAULT_CENTEREDNESS_MARGIN * newBalanceB).mulDown(virtualBalances[0]) /
            virtualBalances[1];
        _setPoolBalances(newBalanceA, newBalanceB);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        assertTrue(ReClammPoolMock(pool).isPoolInRange(), "Pool is out of range");
        assertApproxEqRel(
            ReClammPoolMock(pool).calculatePoolCenteredness(),
            _DEFAULT_CENTEREDNESS_MARGIN,
            1e16,
            "Pool centeredness is not close from margin"
        );

        // Margin will make the pool be out of range (since the current centeredness is near the default margin).
        uint256 newCenterednessMargin = _DEFAULT_CENTEREDNESS_MARGIN + 10e16;
        vm.prank(admin);
        vm.expectRevert(IReClammPool.PoolIsOutOfRange.selector);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);
    }

    function testInRangeUpdatingVirtualBalancesSetCenterednessMargin() public {
        vm.prank(admin);
        // Start updating virtual balances.
        ReClammPool(pool).setPriceRatioState(2e18, block.timestamp, block.timestamp + 1 days);

        vm.warp(block.timestamp + 6 hours);

        // Check if the last virtual balances stored in the pool are different from the current virtual balances.
        uint256[] memory virtualBalancesBefore = ReClammPool(pool).getCurrentVirtualBalances();
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

        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(newCenterednessMargin);
        emit IReClammPool.LastTimestampUpdated(block.timestamp.toUint32());
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balance does not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balance does not match");
    }
}
