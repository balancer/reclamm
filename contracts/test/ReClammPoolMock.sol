// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPool } from "../ReClammPool.sol";
import { ReClammPoolParams } from "../interfaces/IReClammPool.sol";

contract ReClammPoolMock is ReClammPool {
    using SafeCast for uint256;

    constructor(ReClammPoolParams memory params, IVault vault) ReClammPool(params, vault) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setLastTimestamp(uint256 newLastTimestamp) external {
        _lastTimestamp = SafeCast.toUint32(newLastTimestamp);
    }

    function setLastVirtualBalances(uint256[] memory newLastVirtualBalances) external {
        _setLastVirtualBalances(newLastVirtualBalances[0], newLastVirtualBalances[1]);
    }

    function checkInitializationPrices(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) external view {
        _checkInitializationPrices(balancesScaled18, virtualBalanceA, virtualBalanceB);
    }

    function manualSetCenterednessMargin(uint256 newCenterednessMargin) external {
        _centerednessMargin = newCenterednessMargin.toUint64();
    }

    function manualSetPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) external {
        _setPriceRatioState(endFourthRootPriceRatio, priceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }
}
