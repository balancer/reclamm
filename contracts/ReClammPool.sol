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

import { ReClammPoolParams, IReClammPool } from "./interfaces/IReClammPool.sol";
import { SqrtPriceRatioState, ReClammMath } from "./lib/ReClammMath.sol";

contract ReClammPool is IReClammPool, BalancerPoolToken, PoolInfo, BasePoolAuthentication, Version, BaseHooks {
    using FixedPoint for uint256;

    // uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0;
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // A pool is "centered" when it holds equal (non-zero) value in both real token balances. In this state, the ratio
    // of the real balances equals the ratio of the virtual balances, and the value of the centeredness measure is
    // FixedPoint.ONE.
    //
    // As the real balance of either token approaches zero, the centeredness measure likewise approaches zero. Since
    // centeredness is the divisor in many calculations, zero values would revert, and even near-zero values are
    // problematic. Imposing this limit on centeredness (i.e., reverting if an operation would cause the centeredness
    // to decrease below this threshold) keeps the math well-behaved.
    uint256 private constant _MIN_TOKEN_BALANCE_SCALED18 = 1e14;
    uint256 private constant _MIN_POOL_CENTEREDNESS = 1e3;

    SqrtPriceRatioState private _sqrtPriceRatioState;
    uint32 private _lastTimestamp;
    uint128 private _timeConstant;
    uint64 private _centerednessMargin;
    uint256[] private _lastVirtualBalances;

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
                _lastVirtualBalances,
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
    function onSwap(PoolSwapParams memory request) public virtual returns (uint256 amountCalculatedScaled18) {
        // Calculate virtual balances.
        (uint256[] memory currentVirtualBalances, bool changed) = ReClammMath.getCurrentVirtualBalances(
            request.balancesScaled18,
            _lastVirtualBalances,
            _timeConstant,
            _lastTimestamp,
            uint32(block.timestamp),
            _centerednessMargin,
            _sqrtPriceRatioState
        );

        _lastTimestamp = uint32(block.timestamp);

        if (changed) {
            _setVirtualBalances(currentVirtualBalances);
        }

        // Calculate swap result.
        if (request.kind == SwapKind.EXACT_IN) {
            amountCalculatedScaled18 = ReClammMath.calculateOutGivenIn(
                request.balancesScaled18,
                currentVirtualBalances,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
            );

            _ensureValidPoolStateAfterSwap(
                request.balancesScaled18,
                currentVirtualBalances,
                request.amountGivenScaled18,
                amountCalculatedScaled18,
                request.indexIn,
                request.indexOut
            );
        } else {
            amountCalculatedScaled18 = ReClammMath.calculateInGivenOut(
                request.balancesScaled18,
                currentVirtualBalances,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
            );

            _ensureValidPoolStateAfterSwap(
                request.balancesScaled18,
                currentVirtualBalances,
                amountCalculatedScaled18,
                request.amountGivenScaled18,
                request.indexIn,
                request.indexOut
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
        return
            tokenConfig.length == 2 &&
            liquidityManagement.disableUnbalancedLiquidity &&
            liquidityManagement.enableDonation == false;
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
        uint256[] memory currentVirtualBalances = _getCurrentVirtualBalances();
        currentVirtualBalances[0] = currentVirtualBalances[0].mulUp(FixedPoint.ONE + proportion);
        currentVirtualBalances[1] = currentVirtualBalances[1].mulUp(FixedPoint.ONE + proportion);
        _setVirtualBalances(currentVirtualBalances);
        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind,
        uint256 maxBptAmountIn,
        uint256[] memory,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        uint256 totalSupply = _vault.totalSupply(pool);
        uint256 proportion = maxBptAmountIn.divUp(totalSupply);
        uint256[] memory currentVirtualBalances = _getCurrentVirtualBalances();
        currentVirtualBalances[0] = currentVirtualBalances[0].mulDown(FixedPoint.ONE - proportion);
        currentVirtualBalances[1] = currentVirtualBalances[1].mulDown(FixedPoint.ONE - proportion);
        _setVirtualBalances(currentVirtualBalances);

        if (
            balancesScaled18[0].mulDown(proportion.complement()) < _MIN_TOKEN_BALANCE_SCALED18 ||
            balancesScaled18[1].mulDown(proportion.complement()) < _MIN_TOKEN_BALANCE_SCALED18
        ) {
            // If one of the token balances is below 1e18, the update of price ratio is not accurate.
            revert TokenBalanceTooLow();
        }

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
        // The invariant ratio bounds are required by `IBasePool`, but are unused in this pool type, as liquidity can
        // only be added or removed proportionally.
        return 0;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256) {
        // The invariant ratio bounds are required by `IBasePool`, but are unused in this pool type, as liquidity can
        // only be added or removed proportionally.
        return 0;
    }

    /// @inheritdoc IReClammPool
    function getCurrentVirtualBalances() external view returns (uint256[] memory) {
        return _getCurrentVirtualBalances();
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

    function _setVirtualBalances(uint256[] memory virtualBalances) internal {
        _lastVirtualBalances = virtualBalances;

        emit VirtualBalancesUpdated(virtualBalances);
    }

    function _setCenterednessMargin(uint64 centerednessMargin) internal {
        _centerednessMargin = centerednessMargin;

        emit CenterednessMarginUpdated(centerednessMargin);
    }

    function _ensureValidPoolStateAfterSwap(
        uint256[] memory currentBalancesScaled18,
        uint256[] memory currentVirtualBalances,
        uint256 amountInScaled18,
        uint256 amountOutScaled18,
        uint256 indexIn,
        uint256 indexOut
    ) internal pure {
        currentBalancesScaled18[indexIn] += amountInScaled18;
        currentBalancesScaled18[indexOut] -= amountOutScaled18;

        if (currentBalancesScaled18[indexOut] < _MIN_TOKEN_BALANCE_SCALED18) {
            // If one of the token balances is below the minimum, the price ratio update is unreliable.
            revert TokenBalanceTooLow();
        }

        if (
            ReClammMath.calculateCenteredness(currentBalancesScaled18, currentVirtualBalances) < _MIN_POOL_CENTEREDNESS
        ) {
            // If the pool centeredness is below the minimum, the price ratio update is unreliable.
            revert PoolCenterednessTooLow();
        }
    }

    function _getCurrentVirtualBalances() internal view returns (uint256[] memory currentVirtualBalances) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));

        // Calculate virtual balances
        (currentVirtualBalances, ) = ReClammMath.getCurrentVirtualBalances(
            balancesScaled18,
            _lastVirtualBalances,
            _timeConstant,
            _lastTimestamp,
            uint32(block.timestamp),
            _centerednessMargin,
            _sqrtPriceRatioState
        );
    }
}
