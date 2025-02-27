// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {
    IUnbalancedLiquidityInvariantRatioBounds
} from "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import { PoolSwapParams, Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";

contract CustomPool is BalancerPoolToken, PoolInfo, Version, IBasePool {
    uint256 private constant _MAX_INVARIANT_RATIO = 1000e16; // 1000%
    uint256 private constant _MIN_INVARIANT_RATIO = 10e16; // 10%
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 50e16; // 50%
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 1e12; // 0.0001%

    error NotImplemented();

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        string memory poolVersion
    ) BalancerPoolToken(vault, name, symbol) PoolInfo(vault) Version(poolVersion) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory params) external pure returns (uint256 amountCalculatedScaled18) {
        // Simulate a linear pool. If L = x + y, for a given x, return the same amount as y, so the sum is constant.
        return params.amountGivenScaled18;
    }

    /// @inheritdoc IBasePool
    function computeInvariant(
        uint256[] memory balancesLiveScaled18,
        Rounding
    ) external pure returns (uint256 invariant) {
        for (uint256 i = 0; i < balancesLiveScaled18.length; i++) {
            invariant += balancesLiveScaled18[i];
        }
        return invariant;
    }

    /// @inheritdoc IBasePool
    function computeBalance(uint256[] memory, uint256, uint256) external pure returns (uint256) {
        revert NotImplemented();
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure returns (uint256 minimumInvariantRatio) {
        return _MIN_INVARIANT_RATIO;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256 maximumInvariantRatio) {
        return _MAX_INVARIANT_RATIO;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure returns (uint256 minimumSwapFeePercentage) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure returns (uint256 maximumSwapFeePercentage) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }
}
