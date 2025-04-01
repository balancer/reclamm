// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";

contract ReClammPoolTest is BaseReClammTest {
    using FixedPoint for uint256;

    function testGetCurrentFourthRootPriceRatio() public view {
        uint256 fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, _DEFAULT_SQRT_PRICE_RATIO, "Invalid default fourthRootPriceRatio");
    }

    function testSetFourthRootPriceRatio() public {
        uint96 newFourthRootPriceRatio = 2e18;
        uint32 startTime = uint32(block.timestamp);
        uint32 duration = 1 hours;
        uint32 endTime = uint32(block.timestamp) + duration;

        uint96 startFourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.FourthRootPriceRatioUpdated(
            startFourthRootPriceRatio,
            newFourthRootPriceRatio,
            startTime,
            endTime
        );
        ReClammPool(pool).setPriceRatioState(newFourthRootPriceRatio, startTime, endTime);

        skip(duration / 2);
        uint96 fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        uint96 mathFourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            uint32(block.timestamp),
            startFourthRootPriceRatio,
            newFourthRootPriceRatio,
            startTime,
            endTime
        );

        assertEq(fourthRootPriceRatio, mathFourthRootPriceRatio, "FourthRootPriceRatio not updated correctly");

        skip(duration / 2 + 1);
        fourthRootPriceRatio = ReClammPool(pool).getCurrentFourthRootPriceRatio();
        assertEq(fourthRootPriceRatio, newFourthRootPriceRatio, "FourthRootPriceRatio does not match new value");
    }

    function testSetPriceShiftDailyRate() public {
        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceShiftDailyRateUpdated(newPriceShiftDailyRate);
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
        emit IReClammPool.PriceShiftDailyRateUpdated(newPriceShiftDailyRate);
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

    function testSetCenterednessMarginUpdatingVirtualBalance() public {
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

        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(newCenterednessMargin);
        ReClammPool(pool).setCenterednessMargin(newCenterednessMargin);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        // Check if the last virtual balances were updated and are matching the current virtual balances.
        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();
        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balance does not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balance does not match");
    }
}
