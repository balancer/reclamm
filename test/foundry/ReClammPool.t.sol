// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        assertEq(fourthRootPriceRatio, _DEFAULT_FOURTH_ROOT_PRICE_RATIO, "Invalid default fourthRootPriceRatio");
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
        emit IReClammPool.PriceShiftDailyRateUpdated(newPriceShiftDailyRate);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);
    }

    function testSetPriceShiftDailyRateUpdatingVirtualBalance() public {
        _setPoolBalances(1e14, 100e18);
        ReClammPoolMock(pool).setLastTimestamp(block.timestamp);

        vm.warp(block.timestamp + 6 hours);

        uint256[] memory virtualBalancesBefore = ReClammPool(pool).getCurrentVirtualBalances();

        uint256 newPriceShiftDailyRate = 200e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.PriceShiftDailyRateUpdated(newPriceShiftDailyRate);
        ReClammPool(pool).setPriceShiftDailyRate(newPriceShiftDailyRate);

        assertEq(ReClammPool(pool).getLastTimestamp(), block.timestamp, "Last timestamp was not updated");

        uint256[] memory lastVirtualBalances = ReClammPoolMock(pool).getLastVirtualBalances();

        assertEq(lastVirtualBalances[daiIdx], virtualBalancesBefore[daiIdx], "DAI virtual balances do not match");
        assertEq(lastVirtualBalances[usdcIdx], virtualBalancesBefore[usdcIdx], "USDC virtual balances do not match");
    }

    function testSetCenterednessMargin() public {
        // ReCLAMM pools do not have a way to set the margin, so this function uses a mocked version that exposes a
        // private function.
        uint64 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(newCenterednessMargin);
        ReClammPoolMock(pool).setCenterednessMargin(newCenterednessMargin);
    }
}
