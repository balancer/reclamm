// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

/**
 * @notice Mock hook that implements the complement of ReClamm's required hooks.
 * @dev This covers the case where the external hook does not implement the ReClamm required hooks.
 */
contract NonOverlappingHookMock is BaseHooks {
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeSwap = true;
        hookFlags.shouldCallAfterSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
    }

    function onRegister(
        address,
        address,
        TokenConfig[] memory,
        LiquidityManagement calldata
    ) public pure override returns (bool) {
        return true;
    }

    function onBeforeSwap(PoolSwapParams calldata, address) public pure override returns (bool) {
        return true;
    }

    function onAfterSwap(AfterSwapParams calldata) public pure override returns (bool, uint256) {
        return (true, 0);
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata,
        address,
        uint256 staticSwapFeePercentage
    ) public pure override returns (bool, uint256) {
        return (true, staticSwapFeePercentage);
    }
}
