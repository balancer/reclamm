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

    function testGetCurrentSqrtPriceRatio() public view {
        uint256 sqrtPriceRatio = ReClammPool(pool).getCurrentSqrtPriceRatio();
        assertEq(sqrtPriceRatio, _DEFAULT_SQRT_PriceRatio, "Invalid default sqrtPriceRatio");
    }

    function testSetSqrtPriceRatio() public {
        uint96 newSqrtPriceRatio = 2e18;
        uint32 startTime = uint32(block.timestamp);
        uint32 duration = 1 hours;
        uint32 endTime = uint32(block.timestamp) + duration;

        uint96 startSqrtPriceRatio = ReClammPool(pool).getCurrentSqrtPriceRatio();
        vm.prank(admin);
        vm.expectEmit();
        emit IReClammPool.SqrtPriceRatioUpdated(startSqrtPriceRatio, newSqrtPriceRatio, startTime, endTime);
        ReClammPool(pool).setSqrtPriceRatio(newSqrtPriceRatio, startTime, endTime);

        skip(duration / 2);
        uint96 sqrtPriceRatio = ReClammPool(pool).getCurrentSqrtPriceRatio();
        uint96 mathSqrtPriceRatio = ReClammMath.calculateSqrtPriceRatio(
            uint32(block.timestamp),
            startSqrtPriceRatio,
            newSqrtPriceRatio,
            startTime,
            endTime
        );

        assertEq(sqrtPriceRatio, mathSqrtPriceRatio, "SqrtPriceRatio not updated correctly");

        skip(duration / 2 + 1);
        sqrtPriceRatio = ReClammPool(pool).getCurrentSqrtPriceRatio();
        assertEq(sqrtPriceRatio, newSqrtPriceRatio, "SqrtPriceRatio does not match new value");
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
