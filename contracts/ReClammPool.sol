// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolAuthentication } from "@balancer-labs/v3-pool-utils/contracts/BasePoolAuthentication.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import { SqrtPriceRatioState, ReClammMath } from "./lib/ReClammMath.sol";
import { ReClammPoolParams, IReClammPool } from "./interfaces/IReClammPool.sol";

contract ReClammPool is
    IUnbalancedLiquidityInvariantRatioBounds,
    IReClammPool,
    BalancerPoolToken,
    PoolInfo,
    BasePoolAuthentication,
    Version,
    BaseHooks
{
    using FixedPoint for uint256;

    // uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0;
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // Invariant growth limit: non-proportional add cannot cause the invariant to increase by more than this ratio.
    uint256 internal constant _MAX_INVARIANT_RATIO = 300e16; // 300%
    // Invariant shrink limit: non-proportional remove cannot cause the invariant to decrease by less than this ratio.
    uint256 internal constant _MIN_INVARIANT_RATIO = 70e16; // 70%

    SqrtPriceRatioState private _sqrtPriceRatioState;
    uint32 private _lastTimestamp;
    uint128 private _timeConstant;
    uint64 private _centerednessMargin;
    uint256[] private _virtualBalances;

    constructor(
        ReClammPoolParams memory params,
        IVault vault
    )
        BalancerPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        BasePoolAuthentication(vault, msg.sender)
        Version(params.version)
    {
        _setIncreaseDayRate(params.increaseDayRate);
        _setCenterednessMargin(params.centerednessMargin);
        _setSqrtPriceRatio(params.sqrtPriceRatio, 0, uint32(block.timestamp));
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesScaled18, Rounding rounding) public view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                _virtualBalances,
                _timeConstant,
                _lastTimestamp,
                uint32(block.timestamp),
                _centerednessMargin,
                _sqrtPriceRatioState,
                rounding
            );
    }

    /// @inheritdoc IBasePool
    function computeBalance(uint256[] memory, uint256, uint256) external pure returns (uint256) {
        // The pool does not accept unbalanced adds and removes, so this function does not need to be implemented.
        revert NotImplemented();
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory request) public virtual returns (uint256) {
        // Calculate virtual balances
        (uint256[] memory virtualBalances, bool changed) = ReClammMath.getVirtualBalances(
            request.balancesScaled18,
            _virtualBalances,
            _timeConstant,
            _lastTimestamp,
            uint32(block.timestamp),
            _centerednessMargin,
            _sqrtPriceRatioState
        );

        _lastTimestamp = uint32(block.timestamp);

        if (changed) {
            _setVirtualBalances(virtualBalances);
        }

        // Calculate swap result
        if (request.kind == SwapKind.EXACT_IN) {
            return
                ReClammMath.calculateOutGivenIn(
                    request.balancesScaled18,
                    _virtualBalances,
                    request.indexIn,
                    request.indexOut,
                    request.amountGivenScaled18
                );
        } else {
            return
                ReClammMath.calculateInGivenOut(
                    request.balancesScaled18,
                    _virtualBalances,
                    request.indexIn,
                    request.indexOut,
                    request.amountGivenScaled18
                );
        }
    }

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallBeforeInitialize = true;
        hookFlags.shouldCallBeforeAddLiquidity = true;
        hookFlags.shouldCallBeforeRemoveLiquidity = true;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address,
        address,
        TokenConfig[] memory tokenConfig,
        LiquidityManagement calldata liquidityManagement
    ) public view override onlyVault returns (bool) {
        return tokenConfig.length == 2 && liquidityManagement.disableUnbalancedLiquidity;
    }

    /// @inheritdoc IHooks
    function onBeforeInitialize(
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        _lastTimestamp = uint32(block.timestamp);

        uint256 currentSqrtPriceRatio = _calculateCurrentSqrtPriceRatio();
        uint256[] memory virtualBalances = ReClammMath.initializeVirtualBalances(
            balancesScaled18,
            currentSqrtPriceRatio
        );
        _setVirtualBalances(virtualBalances);

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256 minBptAmountOut,
        uint256[] memory,
        bytes memory
    ) public override onlyVault returns (bool) {
        uint256 totalSupply = _vault.totalSupply(pool);
        uint256 proportion = minBptAmountOut.divUp(totalSupply);
        uint256[] memory virtualBalances = _getLastVirtualBalances();
        virtualBalances[0] = virtualBalances[0].mulUp(FixedPoint.ONE + proportion);
        virtualBalances[1] = virtualBalances[1].mulUp(FixedPoint.ONE + proportion);
        _setVirtualBalances(virtualBalances);
        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind,
        uint256 maxBptAmountIn,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public override onlyVault returns (bool) {
        uint256 totalSupply = _vault.totalSupply(pool);
        uint256 proportion = maxBptAmountIn.divUp(totalSupply);
        uint256[] memory virtualBalances = _getLastVirtualBalances();
        virtualBalances[0] = virtualBalances[0].mulDown(FixedPoint.ONE - proportion);
        virtualBalances[1] = virtualBalances[1].mulDown(FixedPoint.ONE - proportion);
        _setVirtualBalances(virtualBalances);
        return true;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure returns (uint256) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure returns (uint256) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure returns (uint256) {
        return _MIN_INVARIANT_RATIO;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256) {
        return _MAX_INVARIANT_RATIO;
    }

    /// @inheritdoc IReClammPool
    function getLastVirtualBalances() external view returns (uint256[] memory) {
        return _getLastVirtualBalances();
    }

    /// @inheritdoc IReClammPool
    function getLastTimestamp() external view returns (uint256) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPool
    function getCurrentSqrtPriceRatio() external view override returns (uint96) {
        return _calculateCurrentSqrtPriceRatio();
    }

    /// @inheritdoc IReClammPool
    function setSqrtPriceRatio(
        uint96 newSqrtPriceRatio,
        uint32 startTime,
        uint32 endTime
    ) external onlySwapFeeManagerOrGovernance(address(this)) {
        _setSqrtPriceRatio(newSqrtPriceRatio, startTime, endTime);
    }

    /// @inheritdoc IReClammPool
    function setIncreaseDayRate(uint256 newIncreaseDayRate) external onlySwapFeeManagerOrGovernance(address(this)) {
        _setIncreaseDayRate(newIncreaseDayRate);
    }

    function _setSqrtPriceRatio(uint96 endSqrtPriceRatio, uint32 startTime, uint32 endTime) internal {
        if (startTime > endTime) {
            revert GradualUpdateTimeTravel(startTime, endTime);
        }

        uint96 startSqrtPriceRatio = _calculateCurrentSqrtPriceRatio();
        _sqrtPriceRatioState.startSqrtPriceRatio = startSqrtPriceRatio;
        _sqrtPriceRatioState.endSqrtPriceRatio = endSqrtPriceRatio;
        _sqrtPriceRatioState.startTime = startTime;
        _sqrtPriceRatioState.endTime = endTime;

        emit SqrtPriceRatioUpdated(startSqrtPriceRatio, endSqrtPriceRatio, startTime, endTime);
    }

    function _calculateCurrentSqrtPriceRatio() internal view returns (uint96) {
        SqrtPriceRatioState memory sqrtPriceRatioState = _sqrtPriceRatioState;

        return
            ReClammMath.calculateSqrtPriceRatio(
                uint32(block.timestamp),
                sqrtPriceRatioState.startSqrtPriceRatio,
                sqrtPriceRatioState.endSqrtPriceRatio,
                sqrtPriceRatioState.startTime,
                sqrtPriceRatioState.endTime
            );
    }

    function _setIncreaseDayRate(uint256 increaseDayRate) internal {
        _timeConstant = ReClammMath.parseIncreaseDayRate(increaseDayRate);

        emit IncreaseDayRateUpdated(increaseDayRate);
    }

    function _setCenterednessMargin(uint64 centerednessMargin) internal {
        _centerednessMargin = centerednessMargin;

        emit CenterednessMarginUpdated(centerednessMargin);
    }

    function _setVirtualBalances(uint256[] memory virtualBalances) internal {
        _virtualBalances = virtualBalances;

        emit VirtualBalancesUpdated(virtualBalances);
    }

    function _getLastVirtualBalances() internal view returns (uint256[] memory virtualBalances) {
        (, , uint256[] memory balancesScaled18, ) = _vault.getPoolTokenInfo(address(this));

        // Calculate virtual balances
        (virtualBalances, ) = ReClammMath.getVirtualBalances(
            balancesScaled18,
            _virtualBalances,
            _timeConstant,
            _lastTimestamp,
            uint32(block.timestamp),
            _centerednessMargin,
            _sqrtPriceRatioState
        );
    }
}
