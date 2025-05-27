// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPool } from "../ReClammPool.sol";
import { ReClammMath, a } from "../lib/ReClammMath.sol";
import { ReClammPoolParams } from "../interfaces/IReClammPool.sol";

contract ReClammPoolMock is ReClammPool {
    using SafeCast for uint256;
    using FixedPoint for uint256;

    constructor(ReClammPoolParams memory params, IVault vault) ReClammPool(params, vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @dev Used to fuzz price ranges and ensure the pool state remains coherent.
    function reInitialize(
        uint256[] memory balancesScaled18,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        uint128 initialPriceShiftDailyRate,
        uint256 centerednessMargin
    ) external returns (uint256 virtualBalanceA, uint256 virtualBalanceB) {
        (
            uint256[] memory theoreticalBalances,
            uint256 theoreticalVirtualBalanceA,
            uint256 theoreticalVirtualBalanceB,
            uint256 fourthRootPriceRatio
        ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

        _checkInitializationBalanceRatio(balancesScaled18, theoreticalBalances);

        uint256 scale = balancesScaled18[a].divDown(theoreticalBalances[a]);

        virtualBalanceA = theoreticalVirtualBalanceA.mulDown(scale);
        virtualBalanceB = theoreticalVirtualBalanceB.mulDown(scale);

        _setLastVirtualBalances(virtualBalanceA, virtualBalanceB);
        _setPriceRatioState(fourthRootPriceRatio, block.timestamp, block.timestamp);

        _dailyPriceShiftBase = initialPriceShiftDailyRate;
        _setCenterednessMargin(centerednessMargin);
        _updateTimestamp();
    }

    function computeInitialBalanceRatio() external view returns (uint256) {
        (uint256 rateA, uint256 rateB) = _getTokenRates();
        return _computeInitialBalanceRatioScaled18(rateA, rateB);
    }

    function computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18
    ) external view returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) {
        return _computeCurrentVirtualBalances(balancesScaled18);
    }

    function setLastTimestamp(uint256 newLastTimestamp) external {
        _lastTimestamp = SafeCast.toUint32(newLastTimestamp);
    }

    function setLastVirtualBalances(uint256[] memory newLastVirtualBalances) external {
        _setLastVirtualBalances(newLastVirtualBalances[0], newLastVirtualBalances[1]);
    }

    function manualSetCenterednessMargin(uint256 newCenterednessMargin) external {
        _centerednessMargin = newCenterednessMargin.toUint64();
    }

    function manualSetPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) external returns (uint256 fourthRootPriceRatioDelta, uint256 startFourthRootPriceRatio) {
        return _setPriceRatioState(endFourthRootPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }
}
