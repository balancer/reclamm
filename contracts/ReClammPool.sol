// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
import { PriceRatioState, ReClammMath } from "./lib/ReClammMath.sol";

contract ReClammPool is IReClammPool, BalancerPoolToken, PoolInfo, BasePoolAuthentication, Version, BaseHooks {
    using SafeCast for *;
    using FixedPoint for uint256;
    using SafeCast for uint256;

    // uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant _MIN_SWAP_FEE_PERCENTAGE = 0;
    uint256 internal constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // The centeredness margin defines the minimum pool centeredness to consider the pool in range. It may be a value
    // from 0 to 100%.
    uint256 internal constant _MIN_CENTEREDNESS_MARGIN = 0;
    uint256 internal constant _MAX_CENTEREDNESS_MARGIN = FixedPoint.ONE;

    // A pool is "centered" when it holds equal (non-zero) value in both real token balances. In this state, the ratio
    // of the real balances equals the ratio of the virtual balances, and the value of the centeredness measure is
    // FixedPoint.ONE.
    //
    // As the real balance of either token approaches zero, the centeredness measure likewise approaches zero. Since
    // centeredness is the divisor in many calculations, zero values would revert, and even near-zero values are
    // problematic. Imposing this limit on centeredness (i.e., reverting if an operation would cause the centeredness
    // to decrease below this threshold) keeps the math well-behaved.
    uint256 internal constant _MIN_TOKEN_BALANCE_SCALED18 = 1e14;
    uint256 internal constant _MIN_POOL_CENTEREDNESS = 1e3;

    PriceRatioState internal _priceRatioState;
    uint32 internal _lastTimestamp;
    uint128 internal _timeConstant;
    uint64 internal _centerednessMargin;
    uint256[] internal _lastVirtualBalances;

    modifier onlyWhenVaultIsLocked() {
        if (_vault.isUnlocked()) {
            revert VaultIsNotLocked();
        }
        _;
    }

    modifier onlyWhenPoolIsInRange() {
        if (_isPoolInRange() == false) {
            revert PoolIsOutOfRange();
        }
        _;
        if (_isPoolInRange() == false) {
            revert PoolIsOutOfRange();
        }
    }

    constructor(
        ReClammPoolParams memory params,
        IVault vault
    )
        BalancerPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        BasePoolAuthentication(vault, msg.sender)
        Version(params.version)
    {
        _setPriceShiftDailyRate(params.priceShiftDailyRate);
        _setCenterednessMargin(params.centerednessMargin);
        _setPriceRatioState(params.fourthRootPriceRatio, 0, block.timestamp);
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesScaled18, Rounding rounding) public view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                _lastVirtualBalances,
                _timeConstant,
                _lastTimestamp,
                _centerednessMargin,
                _priceRatioState,
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
        (uint256[] memory currentVirtualBalances, bool changed) = _getCurrentVirtualBalances(request.balancesScaled18);

        if (changed) {
            _setLastVirtualBalances(currentVirtualBalances);
        }

        _updateTimestamp();

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
        uint256 currentFourthRootPriceRatio = _calculateCurrentFourthRootPriceRatio();
        uint256[] memory virtualBalances = ReClammMath.initializeVirtualBalances(
            balancesScaled18,
            currentFourthRootPriceRatio
        );
        _setLastVirtualBalances(virtualBalances);
        _updateTimestamp();

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256 minBptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        // This hook makes sure that the virtual balances are increased in the same proportion as the real balances
        // after adding liquidity. This is needed to keep the pool centeredness and price ratio constant.

        uint256 totalSupply = _vault.totalSupply(pool);
        // Rounding proportion up, which will round the virtual balances up.
        uint256 proportion = minBptAmountOut.divUp(totalSupply);

        (uint256[] memory currentVirtualBalances, ) = _getCurrentVirtualBalances(balancesScaled18);
        // When adding/removing liquidity, round up the virtual balances. This will result in a higher invariant,
        // which favors the vault in swap operations. The virtual balances are not used to calculate a proportional
        // add/remove result.
        currentVirtualBalances[0] = currentVirtualBalances[0].mulUp(FixedPoint.ONE + proportion);
        currentVirtualBalances[1] = currentVirtualBalances[1].mulUp(FixedPoint.ONE + proportion);
        _setLastVirtualBalances(currentVirtualBalances);
        _updateTimestamp();

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
        // This hook makes sure that the virtual balances are decreased in the same proportion as the real balances
        // after removing liquidity. This is needed to keep the pool centeredness and price ratio constant.

        uint256 totalSupply = _vault.totalSupply(pool);
        // Rounding proportion down, which will round the virtual balances up.
        uint256 proportion = maxBptAmountIn.divDown(totalSupply);

        (uint256[] memory currentVirtualBalances, ) = _getCurrentVirtualBalances(balancesScaled18);
        // When adding/removing liquidity, round up the virtual balances. This will result in a higher invariant,
        // which favors the vault in swap operations. The virtual balances are not used to calculate a proportional
        // add/remove result.
        currentVirtualBalances[0] = currentVirtualBalances[0].mulUp(FixedPoint.ONE - proportion);
        currentVirtualBalances[1] = currentVirtualBalances[1].mulUp(FixedPoint.ONE - proportion);
        _setLastVirtualBalances(currentVirtualBalances);
        _updateTimestamp();

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
    function getCurrentVirtualBalances() external view returns (uint256[] memory currentVirtualBalances) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (currentVirtualBalances, ) = _getCurrentVirtualBalances(balancesScaled18);
    }

    /// @inheritdoc IReClammPool
    function getLastTimestamp() external view returns (uint32) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPool
    function getCurrentFourthRootPriceRatio() external view override returns (uint96) {
        return _calculateCurrentFourthRootPriceRatio();
    }

    /// @inheritdoc IReClammPool
    function setPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 startTime,
        uint256 endTime
    ) external onlySwapFeeManagerOrGovernance(address(this)) {
        _setPriceRatioState(endFourthRootPriceRatio, startTime, endTime);
    }

    /// @inheritdoc IReClammPool
    function setPriceShiftDailyRate(
        uint256 newPriceShiftDailyRate
    ) external onlySwapFeeManagerOrGovernance(address(this)) {
        // Update virtual balances before updating the daily rate.
        _setPriceShiftDailyRateAndUpdateVirtualBalances(newPriceShiftDailyRate);
    }

    /// @inheritdoc IReClammPool
    function setCenterednessMargin(
        uint256 newCenterednessMargin
    ) external onlySwapFeeManagerOrGovernance(address(this)) {
        _setCenterednessMarginAndUpdateVirtualBalances(newCenterednessMargin);
    }

    function _getCurrentVirtualBalances(
        uint256[] memory balancesScaled18
    ) internal view returns (uint256[] memory currentVirtualBalances, bool changed) {
        (currentVirtualBalances, changed) = ReClammMath.getCurrentVirtualBalances(
            balancesScaled18,
            _lastVirtualBalances,
            _timeConstant,
            _lastTimestamp,
            _centerednessMargin,
            _priceRatioState
        );
    }

    function _setLastVirtualBalances(uint256[] memory virtualBalances) internal {
        _lastVirtualBalances = virtualBalances;

        emit VirtualBalancesUpdated(virtualBalances);
    }

    function _setPriceRatioState(uint256 endFourthRootPriceRatio, uint256 startTime, uint256 endTime) internal {
        if (startTime > endTime) {
            revert GradualUpdateTimeTravel(startTime, endTime);
        }

        uint96 startFourthRootPriceRatio = _calculateCurrentFourthRootPriceRatio();
        uint96 endFourthRootPriceRatio96 = endFourthRootPriceRatio.toUint96();
        _priceRatioState.startFourthRootPriceRatio = startFourthRootPriceRatio == 0
            ? endFourthRootPriceRatio96
            : startFourthRootPriceRatio;
        _priceRatioState.endFourthRootPriceRatio = endFourthRootPriceRatio96;
        _priceRatioState.startTime = startTime.toUint32();
        _priceRatioState.endTime = endTime.toUint32();

        emit PriceRatioStateUpdated(startFourthRootPriceRatio, endFourthRootPriceRatio, startTime, endTime);
    }

    /// Using the pool balances to update the virtual balances is dangerous with an unlocked vault, since the balances
    /// are manipulable.
    function _setPriceShiftDailyRateAndUpdateVirtualBalances(
        uint256 priceShiftDailyRate
    ) internal onlyWhenVaultIsLocked {
        // Update virtual balances with current daily rate.
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (uint256[] memory currentVirtualBalances, bool changed) = _getCurrentVirtualBalances(balancesScaled18);
        if (changed) {
            _setLastVirtualBalances(currentVirtualBalances);
        }
        _updateTimestamp();

        // Update time constant.
        _setPriceShiftDailyRate(priceShiftDailyRate);
    }

    function _setPriceShiftDailyRate(uint256 priceShiftDailyRate) internal {
        _timeConstant = ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);

        emit PriceShiftDailyRateUpdated(priceShiftDailyRate);
    }

    /**
     * @dev This function relies on the pool balance, which can be manipulated if the vault is unlocked. Also, the pool
     * must be in range before and after the operation, or the pool owner could arb the pool.
     */
    function _setCenterednessMarginAndUpdateVirtualBalances(
        uint256 centerednessMargin
    ) internal onlyWhenVaultIsLocked onlyWhenPoolIsInRange {
        // Update the virtual balances using the current daily rate.
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (uint256[] memory currentVirtualBalances, bool changed) = _getCurrentVirtualBalances(balancesScaled18);
        if (changed) {
            _setLastVirtualBalances(currentVirtualBalances);
        }

        _updateTimestamp();

        _setCenterednessMargin(centerednessMargin);
    }

    /**
     * @notice Sets the centeredness margin when the pool is created.
     * @param centerednessMargin A percentage (0-100%) below which the pool is considered out of range
     */
    function _setCenterednessMargin(uint256 centerednessMargin) internal {
        if (centerednessMargin < _MIN_CENTEREDNESS_MARGIN || centerednessMargin > _MAX_CENTEREDNESS_MARGIN) {
            revert InvalidCenterednessMargin();
        }

        _centerednessMargin = centerednessMargin.toUint64();

        emit CenterednessMarginUpdated(centerednessMargin);
    }

    // Updates the last timestamp to the current timestamp.
    function _updateTimestamp() internal {
        _lastTimestamp = block.timestamp.toUint32();
    }

    /**
     * @notice Ensures the pool state is valid after a swap.
     * @dev This function ensures that the balance of each token is greater than the minimum balance after a swap.
     * It further verifies that the pool does not end up too unbalanced, by ensuring the pool centeredness is above
     * the minimum. A unbalanced pool, with balances near the minimum/maximum price points, can result in large
     * rounding errors in the swap calculations.
     *
     * @param currentBalancesScaled18 The current balances of the pool, sorted in token registration order
     * @param currentVirtualBalances The current virtual balances of the pool, sorted in token registration order
     * @param amountInScaled18 Amount of tokenIn (entering the Vault)
     * @param amountOutScaled18 Amount of tokenOut (leaving the Vault)
     * @param indexIn The zero-based index of tokenIn
     * @param indexOut The zero-based index of tokenOut
     */
    function _ensureValidPoolStateAfterSwap(
        uint256[] memory currentBalancesScaled18,
        uint256[] memory currentVirtualBalances,
        uint256 amountInScaled18,
        uint256 amountOutScaled18,
        uint256 indexIn,
        uint256 indexOut
    ) internal pure {
        currentBalancesScaled18[indexIn] += amountInScaled18;
        // The swap functions `calculateOutGivenIn` and `calculateInGivenOut` ensure that the amountOutScaled18 is
        // never greater than the balance of the token being swapped out. Therefore, the math below will never
        // underflow. Nevertheless, since these considerations involve code outside this function, it is safest
        // to still use checked math here.
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

    /**
     * @notice Returns the current fourth root of price ratio.
     * @dev This function uses the current timestamp and full price ratio state to compute the current fourth root
     * price ratio value by linear interpolation between the start and end times and values.
     *
     * @return currentFourthRootPriceRatio The current fourth root of price ratio
     */
    function _calculateCurrentFourthRootPriceRatio() internal view returns (uint96 currentFourthRootPriceRatio) {
        PriceRatioState memory priceRatioState = _priceRatioState;

        currentFourthRootPriceRatio = ReClammMath.calculateFourthRootPriceRatio(
            block.timestamp.toUint32(),
            priceRatioState.startFourthRootPriceRatio,
            priceRatioState.endFourthRootPriceRatio,
            priceRatioState.startTime,
            priceRatioState.endTime
        );
    }

    /// @dev This function relies on the pool balance, which can be manipulated if the vault is unlocked.
    function _isPoolInRange() internal view onlyWhenVaultIsLocked returns (bool) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));

        return ReClammMath.isPoolInRange(balancesScaled18, _lastVirtualBalances, _centerednessMargin);
    }
}
