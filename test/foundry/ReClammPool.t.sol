// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GyroPoolMath } from "@balancer-labs/v3-pool-gyro/contracts/lib/GyroPoolMath.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";

contract ReClammPoolTest is BaseReClammTest {
    using FixedPoint for uint256;

    function testGetCurrentSqrtQ0() public view {
        uint256 sqrtQ0 = ReClammPool(pool).getCurrentSqrtQ0();
        assertEq(sqrtQ0, _DEFAULT_SQRT_Q0, "Invalid default sqrtQ0");
    }

    function testSetSqrtQ0() public {
        uint96 newSqrtQ0 = 2e18;
        uint32 startTime = uint32(block.timestamp);
        uint32 duration = 1 hours;
        uint32 endTime = uint32(block.timestamp) + duration;

        uint96 startSqrtQ0 = ReClammPool(pool).getCurrentSqrtQ0();
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.SqrtQ0Updated(startSqrtQ0, newSqrtQ0, startTime, endTime);
        ReClammPool(pool).setSqrtQ0(newSqrtQ0, startTime, endTime);

        skip(duration / 2);
        uint96 sqrtQ0 = ReClammPool(pool).getCurrentSqrtQ0();
        uint96 mathSqrtQ0 = ReClammMath.calculateSqrtQ0(
            uint32(block.timestamp),
            startSqrtQ0,
            newSqrtQ0,
            startTime,
            endTime
        );

        assertEq(sqrtQ0, mathSqrtQ0, "SqrtQ0 not updated correctly");

        skip(duration / 2 + 1);
        sqrtQ0 = ReClammPool(pool).getCurrentSqrtQ0();
        assertEq(sqrtQ0, newSqrtQ0, "SqrtQ0 does not match new value");
    }

    function testSetIncreaseDayRate() public {
        uint256 newIncreaseDayRate = 200e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.IncreaseDayRateUpdated(newIncreaseDayRate);
        ReClammPool(pool).setIncreaseDayRate(newIncreaseDayRate);
    }

    function testSetCenterednessMargin() public {
        // ReCLAMM pools do not have a way to set the margin, so this function uses a mocked version that exposes a
        // private function.
        uint256 newCenterednessMargin = 50e16;
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.CenterednessMarginUpdated(newCenterednessMargin);
        ReClammPoolMock(pool).setCenterednessMargin(newCenterednessMargin);
    }
}
