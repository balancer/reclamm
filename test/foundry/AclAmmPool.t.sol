// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GyroPoolMath } from "@balancer-labs/v3-pool-gyro/contracts/lib/GyroPoolMath.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseAclAmmTest } from "./utils/BaseAclAmmTest.sol";
import { AclAmmPool } from "../../contracts/AclAmmPool.sol";
import { AclAmmMath } from "../../contracts/lib/AclAmmMath.sol";
import { IAclAmmPool } from "../../contracts/interfaces/IAclAmmPool.sol";

contract AclAmmPoolTest is BaseAclAmmTest {
    using FixedPoint for uint256;

    function testEmitsInitializationEvent() public {
        // Deploy a new pool to test the initialization event
        address[] memory tokens = new address[](2);
        tokens[0] = address(dai);
        tokens[1] = address(usdc);

        vm.expectEmit();
        emit IAclAmmPool.AclAmmPoolInitialized(
            _DEFAULT_INCREASE_DAY_RATE,
            _DEFAULT_SQRT_Q0,
            _DEFAULT_CENTEREDNESS_MARGIN
        );

        _createPool(tokens, "Test Pool");
    }

    function testGetCurrentSqrtQ0() public view {
        uint256 sqrtQ0 = AclAmmPool(pool).getCurrentSqrtQ0();
        assertEq(sqrtQ0, _DEFAULT_SQRT_Q0, "Invalid default sqrtQ0");
    }

    function testSetSqrtQ0() public {
        uint256 newSqrtQ0 = 2e18;
        uint256 startTime = block.timestamp;
        uint256 duration = 1 hours;
        uint256 endTime = block.timestamp + duration;

        uint256 startSqrtQ0 = AclAmmPool(pool).getCurrentSqrtQ0();
        vm.prank(admin);
        vm.expectEmit();
        emit IAclAmmPool.SqrtQ0Updated(startSqrtQ0, newSqrtQ0, startTime, endTime);
        AclAmmPool(pool).setSqrtQ0(newSqrtQ0, startTime, endTime);

        skip(duration / 2);
        uint256 sqrtQ0 = AclAmmPool(pool).getCurrentSqrtQ0();
        uint256 mathSqrtQ0 = AclAmmMath.calculateSqrtQ0(block.timestamp, startSqrtQ0, newSqrtQ0, startTime, endTime);

        assertEq(sqrtQ0, mathSqrtQ0, "SqrtQ0 not updated correctly");

        skip(duration / 2 + 1);
        sqrtQ0 = AclAmmPool(pool).getCurrentSqrtQ0();
        assertEq(sqrtQ0, newSqrtQ0, "SqrtQ0 does not match new value");
    }
}
