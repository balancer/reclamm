// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { IReClammErrors } from "./interfaces/IReClammErrors.sol";
import { IReClammEvents } from "./interfaces/IReClammEvents.sol";
import { ReClammStorage } from "./ReClammStorage.sol";
import { PriceRatioState, ReClammMath } from "./lib/ReClammMath.sol";

/**
 * @notice Functions and modifiers shared between the main Vault and its extension contracts.
 * @dev This contract contains common utilities in the inheritance chain that require storage to work,
 * and will be required in both the main Vault and its extensions.
 */
abstract contract ReClammCommon is IReClammEvents, IReClammErrors, ReClammStorage {
    using SafeCast for *;

    function _getBalancerVault() internal view virtual returns (IVault);

    /**
     * @notice Computes the fourth root of the current price ratio.
     * @dev The function calculates the price ratio between tokens A and B using their real and virtual balances,
     * then takes the fourth root of this ratio. The multiplication by FixedPoint.ONE before each sqrt operation
     * is done to maintain precision in the fixed-point calculations.
     *
     * @return The fourth root of the current price ratio, maintaining precision through fixed-point arithmetic
     */
    function _computeCurrentPriceRatio() internal view returns (uint256) {
        (, , , uint256[] memory balancesScaled18) = _getBalancerVault().getPoolTokenInfo(address(this));
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = _computeCurrentVirtualBalances(balancesScaled18);

        return ReClammMath.computePriceRatio(balancesScaled18, virtualBalanceA, virtualBalanceB);
    }

    function _computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18
    ) internal view returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) {
        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = ReClammMath.computeCurrentVirtualBalances(
            balancesScaled18,
            _lastVirtualBalanceA,
            _lastVirtualBalanceB,
            _dailyPriceShiftBase,
            _lastTimestamp,
            _centerednessMargin,
            _priceRatioState
        );
    }

    function _startPriceRatioUpdate(
        uint256 endPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) internal returns (uint256 startPriceRatio) {
        if (priceRatioUpdateStartTime > priceRatioUpdateEndTime || priceRatioUpdateStartTime < block.timestamp) {
            revert InvalidStartTime();
        }

        PriceRatioState memory priceRatioState = _priceRatioState;

        uint256 endFourthRootPriceRatio = ReClammMath.fourthRootScaled18(endPriceRatio);

        uint256 startFourthRootPriceRatio;
        if (_getBalancerVault().isPoolInitialized(address(this))) {
            startPriceRatio = _computeCurrentPriceRatio();
            startFourthRootPriceRatio = ReClammMath.fourthRootScaled18(startPriceRatio);
        } else {
            startFourthRootPriceRatio = endFourthRootPriceRatio;
            startPriceRatio = endPriceRatio;
        }

        priceRatioState.startFourthRootPriceRatio = startFourthRootPriceRatio.toUint96();
        priceRatioState.endFourthRootPriceRatio = endFourthRootPriceRatio.toUint96();
        priceRatioState.priceRatioUpdateStartTime = priceRatioUpdateStartTime.toUint32();
        priceRatioState.priceRatioUpdateEndTime = priceRatioUpdateEndTime.toUint32();

        _priceRatioState = priceRatioState;

        emit PriceRatioStateUpdated(
            startFourthRootPriceRatio,
            endFourthRootPriceRatio,
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        _getBalancerVault().emitAuxiliaryEvent(
            "PriceRatioStateUpdated",
            abi.encode(
                startFourthRootPriceRatio,
                endFourthRootPriceRatio,
                priceRatioUpdateStartTime,
                priceRatioUpdateEndTime
            )
        );
    }
}
