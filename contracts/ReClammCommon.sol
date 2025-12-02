// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammStorage } from "./ReClammStorage.sol";
import { ReClammMath } from "./lib/ReClammMath.sol";

/**
 * @notice Functions and modifiers shared between the main ReClammPool and its extension contract.
 * @dev This contract contains common utilities in the inheritance chain that require storage to work,
 * and will be required in both the main ReClammPool and its extension.
 */
abstract contract ReClammCommon is ReClammStorage {
    using SafeCast for *;

    /// @notice The function is not implemented.
    error NotImplemented();

    /*******************************************************************************
                               Shared Internal Functions
    *******************************************************************************/

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

    /*******************************************************************************
                                    Proxy Functions
    *******************************************************************************/

    // The Vault is stored immutably (through VaultGuard) in both contracts. To avoid name collisions, define this
    // function in both to enable referencing the Vault in common code.
    function _getBalancerVault() internal view virtual returns (IVault);
}
