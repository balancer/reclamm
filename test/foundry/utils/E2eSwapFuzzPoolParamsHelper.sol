// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BaseReClammTest } from "./BaseReClammTest.sol";
import { ReClammPool } from "../../../contracts/ReClammPool.sol";

contract E2eSwapFuzzPoolParamsHelper is Test {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 private constant POOL_SPECIFIC_PARAMS_SIZE = 5;
    uint256 private constant MAX_BALANCE = 1_000 * FixedPoint.ONE;
    uint256 private constant MIN_PRICE = FixedPoint.ONE;
    uint256 private constant MAX_PRICE = 1_000 * FixedPoint.ONE;
    uint256 private constant MAX_DAYS_FOR_PRICE_CHANGE = 10 days;

    function _fuzzPoolParams(
        uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params,
        ReClammPool pool,
        IRouter router,
        address sender
    ) internal {
        uint256 maxBPT = pool.computeInvariant([MAX_BALANCE, MAX_BALANCE].toMemoryArray(), Rounding.ROUND_UP);
        uint256 exactBptAmountOut = bound(params[0], FixedPoint.ONE, maxBPT);

        uint256 minPrice = bound(params[1], MIN_PRICE, MAX_PRICE);
        uint256 maxPrice = bound(params[2], minPrice, MAX_PRICE);

        uint256 priceRatio = maxPrice.divDown(minPrice);
        uint96 endFourthRootPriceRatio = SafeCast.toUint96(
            Math.sqrt(Math.sqrt(priceRatio * FixedPoint.ONE) * FixedPoint.ONE)
        );

        uint256 currentTime = block.timestamp;
        uint256 maxTime = currentTime + MAX_DAYS_FOR_PRICE_CHANGE;
        uint256 startTime = bound(params[3], currentTime, maxTime);
        uint256 endTime = bound(params[4], startTime, maxTime);

        vm.startPrank(sender);
        if (exactBptAmountOut > 0) {
            router.addLiquidityProportional(
                address(pool),
                [uint256(type(uint128).max), type(uint128).max].toMemoryArray(),
                exactBptAmountOut,
                false,
                new bytes(0)
            );
        }

        pool.setPriceRatioState(endFourthRootPriceRatio, startTime, endTime);
        vm.stopPrank();
    }
}
