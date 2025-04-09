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
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import {
    ReClammPoolParams,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData,
    IReClammPool
} from "./interfaces/IReClammPool.sol";
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

    uint256 internal constant _MAX_PRICE_SHIFT_DAILY_RATE = 500e16; // 500%

    uint256 internal constant _MIN_PRICE_RATIO_UPDATE_DURATION = 6 hours;

    uint256 internal constant _BALANCE_RATIO_AND_PRICE_TOLERANCE = 1e14; // 0.01%

    uint256 private immutable _INITIAL_MIN_PRICE;
    uint256 private immutable _INITIAL_MAX_PRICE;
    uint256 private immutable _INITIAL_TARGET_PRICE;

    PriceRatioState internal _priceRatioState;
    uint32 internal _lastTimestamp;
    uint128 internal _priceShiftDailyRangeInSeconds;
    uint64 internal _centerednessMargin;
    uint256[] internal _lastVirtualBalances;

    modifier onlyWhenVaultIsLocked() {
        if (_vault.isUnlocked()) {
            revert VaultIsNotLocked();
        }
        _;
    }

    modifier onlyWhenInitialized() {
        if (_vault.isPoolInitialized(address(this)) == false) {
            revert PoolNotInitialized();
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
        // Initialize immutable params. They are used only during pool initialization.
        _INITIAL_MIN_PRICE = params.initialMinPrice;
        _INITIAL_MAX_PRICE = params.initialMaxPrice;
        _INITIAL_TARGET_PRICE = params.initialTargetPrice;

        // Set dynamic parameters.
        _setPriceShiftDailyRate(params.priceShiftDailyRate);
        _setCenterednessMargin(params.centerednessMargin);
    }

    /********************************************************
                    Base Pool Functions
    ********************************************************/

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesScaled18, Rounding rounding) public view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                _lastVirtualBalances,
                _priceShiftDailyRangeInSeconds,
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
    function onSwap(PoolSwapParams memory request) public virtual onlyVault returns (uint256 amountCalculatedScaled18) {
        (uint256[] memory currentVirtualBalances, bool changed) = _computeCurrentVirtualBalances(
            request.balancesScaled18
        );

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

    /// @inheritdoc IRateProvider
    function getRate() public pure override returns (uint256) {
        revert ReClammPoolBptRateUnsupported();
    }

    /********************************************************
                        Hooks Functions
    ********************************************************/

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
        (
            uint256[] memory theoreticalRealBalances,
            uint256[] memory theoreticalVirtualBalances,
            uint256 fourthRootPriceRatio
        ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
                _INITIAL_MIN_PRICE,
                _INITIAL_MAX_PRICE,
                _INITIAL_TARGET_PRICE
            );

        _checkInitializationBalanceRatio(balancesScaled18, theoreticalRealBalances);

        uint256 scale = balancesScaled18[0].divDown(theoreticalRealBalances[0]);

        uint256[] memory virtualBalances = new uint256[](2);
        virtualBalances[0] = theoreticalVirtualBalances[0].mulDown(scale);
        virtualBalances[1] = theoreticalVirtualBalances[1].mulDown(scale);

        _checkInitializationPrices(balancesScaled18, virtualBalances);

        if (ReClammMath.computeCenteredness(balancesScaled18, virtualBalances) < _centerednessMargin) {
            revert PoolCenterednessTooLow();
        }

        _setLastVirtualBalances(virtualBalances);
        _setPriceRatioState(fourthRootPriceRatio, block.timestamp, block.timestamp);
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

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(balancesScaled18);
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

        (uint256[] memory currentVirtualBalances, ) = _computeCurrentVirtualBalances(balancesScaled18);
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

    /********************************************************
                        Pool State Getters
    ********************************************************/

    /// @inheritdoc IReClammPool
    function computeInitialBalanceRatio() external view returns (uint256 balanceRatio) {
        (uint256[] memory realBalances, , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            _INITIAL_MIN_PRICE,
            _INITIAL_MAX_PRICE,
            _INITIAL_TARGET_PRICE
        );
        balanceRatio = realBalances[1].divDown(realBalances[0]);
    }

    /// @inheritdoc IReClammPool
    function computeCurrentVirtualBalances()
        external
        view
        returns (uint256[] memory currentVirtualBalances, bool changed)
    {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (currentVirtualBalances, changed) = _computeCurrentVirtualBalances(balancesScaled18);
    }

    /// @inheritdoc IReClammPool
    function getLastTimestamp() external view returns (uint32) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPool
    function getLastVirtualBalances() external view returns (uint256[] memory) {
        return _lastVirtualBalances;
    }

    /// @inheritdoc IReClammPool
    function getCenterednessMargin() external view returns (uint256) {
        return _centerednessMargin;
    }

    /// @inheritdoc IReClammPool
    function getPriceShiftDailyRateInSeconds() external view returns (uint256) {
        return _priceShiftDailyRangeInSeconds;
    }

    /// @inheritdoc IReClammPool
    function getPriceRatioState() external view returns (PriceRatioState memory) {
        return _priceRatioState;
    }

    /// @inheritdoc IReClammPool
    function computeCurrentFourthRootPriceRatio() external view returns (uint256) {
        return _computeCurrentFourthRootPriceRatio(_priceRatioState);
    }

    /// @inheritdoc IReClammPool
    function isPoolInRange() external view returns (bool) {
        return _isPoolInRange();
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPoolCenteredness() external view returns (uint256) {
        (, , , uint256[] memory currentBalancesScaled18) = _vault.getPoolTokenInfo(address(this));
        return ReClammMath.computeCenteredness(currentBalancesScaled18, _lastVirtualBalances);
    }

    /// @inheritdoc IReClammPool
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data) {
        data.balancesLiveScaled18 = _vault.getCurrentLiveBalances(address(this));
        (, data.tokenRates) = _vault.getPoolTokenRates(address(this));
        data.staticSwapFeePercentage = _vault.getStaticSwapFeePercentage((address(this)));
        data.totalSupply = totalSupply();

        data.lastTimestamp = _lastTimestamp;
        data.lastVirtualBalances = _lastVirtualBalances;
        data.priceShiftDailyRangeInSeconds = _priceShiftDailyRangeInSeconds;
        data.centerednessMargin = _centerednessMargin;

        data.currentFourthRootPriceRatio = _computeCurrentFourthRootPriceRatio(_priceRatioState);

        PriceRatioState memory state = _priceRatioState;
        data.startFourthRootPriceRatio = state.startFourthRootPriceRatio;
        data.endFourthRootPriceRatio = state.endFourthRootPriceRatio;
        data.priceRatioUpdateStartTime = state.priceRatioUpdateStartTime;
        data.priceRatioUpdateEndTime = state.priceRatioUpdateEndTime;

        PoolConfig memory poolConfig = _vault.getPoolConfig(address(this));
        data.isPoolInitialized = poolConfig.isPoolInitialized;
        data.isPoolPaused = poolConfig.isPoolPaused;
        data.isPoolInRecoveryMode = poolConfig.isPoolInRecoveryMode;
    }

    /// @inheritdoc IReClammPool
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data) {
        data.tokens = _vault.getPoolTokens(address(this));
        (data.decimalScalingFactors, ) = _vault.getPoolTokenRates(address(this));
        data.initialMinPrice = _INITIAL_MIN_PRICE;
        data.initialMaxPrice = _INITIAL_MAX_PRICE;
        data.initialTargetPrice = _INITIAL_TARGET_PRICE;
        data.minCenterednessMargin = _MIN_CENTEREDNESS_MARGIN;
        data.maxCenterednessMargin = _MAX_CENTEREDNESS_MARGIN;
        data.minTokenBalanceScaled18 = _MIN_TOKEN_BALANCE_SCALED18;
        data.minPoolCenteredness = _MIN_POOL_CENTEREDNESS;
        data.maxPriceShiftDailyRate = _MAX_PRICE_SHIFT_DAILY_RATE;
        data.minPriceRatioUpdateDuration = _MIN_PRICE_RATIO_UPDATE_DURATION;
    }

    /********************************************************   
                        Pool State Setters
    ********************************************************/

    /// @inheritdoc IReClammPool
    function setPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    )
        external
        onlySwapFeeManagerOrGovernance(address(this))
        onlyWhenInitialized
        returns (uint256 actualPriceRatioUpdateStartTime)
    {
        actualPriceRatioUpdateStartTime = GradualValueChange.resolveStartTime(
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        // We've already validated that end time >= start time at this point.
        if (priceRatioUpdateEndTime - actualPriceRatioUpdateStartTime < _MIN_PRICE_RATIO_UPDATE_DURATION) {
            revert PriceRatioUpdateDurationTooShort();
        }

        _setPriceRatioState(endFourthRootPriceRatio, actualPriceRatioUpdateStartTime, priceRatioUpdateEndTime);
    }

    /// @inheritdoc IReClammPool
    function setPriceShiftDailyRate(
        uint256 newPriceShiftDailyRate
    ) external onlyWhenInitialized onlySwapFeeManagerOrGovernance(address(this)) {
        // Update virtual balances before updating the daily rate.
        _setPriceShiftDailyRateAndUpdateVirtualBalances(newPriceShiftDailyRate);
    }

    /// @inheritdoc IReClammPool
    function setCenterednessMargin(
        uint256 newCenterednessMargin
    ) external onlyWhenInitialized onlySwapFeeManagerOrGovernance(address(this)) {
        _setCenterednessMarginAndUpdateVirtualBalances(newCenterednessMargin);
    }

    /********************************************************
                        Internal Helpers
    ********************************************************/

    function _computeCurrentVirtualBalances(
        uint256[] memory balancesScaled18
    ) internal view returns (uint256[] memory currentVirtualBalances, bool changed) {
        (currentVirtualBalances, changed) = ReClammMath.computeCurrentVirtualBalances(
            balancesScaled18,
            _lastVirtualBalances,
            _priceShiftDailyRangeInSeconds,
            _lastTimestamp,
            _centerednessMargin,
            _priceRatioState
        );
    }

    function _setLastVirtualBalances(uint256[] memory virtualBalances) internal {
        _lastVirtualBalances = virtualBalances;

        emit VirtualBalancesUpdated(virtualBalances);
    }

    function _setPriceRatioState(
        uint256 endFourthRootPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    ) internal {
        if (priceRatioUpdateStartTime > priceRatioUpdateEndTime || priceRatioUpdateStartTime < block.timestamp) {
            revert InvalidStartTime();
        }

        PriceRatioState memory priceRatioState = _priceRatioState;

        uint256 startFourthRootPriceRatio = _computeCurrentFourthRootPriceRatio(priceRatioState);

        if (startFourthRootPriceRatio == endFourthRootPriceRatio) {
            revert PriceRatioUnchanged();
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
    }

    /// Using the pool balances to update the virtual balances is dangerous with an unlocked vault, since the balances
    /// are manipulable.
    function _setPriceShiftDailyRateAndUpdateVirtualBalances(
        uint256 priceShiftDailyRate
    ) internal onlyWhenVaultIsLocked {
        // Update virtual balances with current daily rate.
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (uint256[] memory currentVirtualBalances, bool changed) = _computeCurrentVirtualBalances(balancesScaled18);
        if (changed) {
            _setLastVirtualBalances(currentVirtualBalances);
        }
        _updateTimestamp();

        // Update time constant.
        _setPriceShiftDailyRate(priceShiftDailyRate);
    }

    function _setPriceShiftDailyRate(uint256 priceShiftDailyRate) internal {
        if (priceShiftDailyRate > _MAX_PRICE_SHIFT_DAILY_RATE) {
            revert PriceShiftDailyRateTooHigh();
        }

        _priceShiftDailyRangeInSeconds = ReClammMath.computePriceShiftDailyRate(priceShiftDailyRate);

        emit PriceShiftDailyRateUpdated(priceShiftDailyRate, _priceShiftDailyRangeInSeconds);
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
        (uint256[] memory currentVirtualBalances, bool changed) = _computeCurrentVirtualBalances(balancesScaled18);
        if (changed) {
            _setLastVirtualBalances(currentVirtualBalances);
        }

        _updateTimestamp();

        _setCenterednessMargin(centerednessMargin);
    }

    /**
     * @notice Sets the centeredness margin when the pool is created.
     * @param centerednessMargin The new centerednessMargin value, which must be within range
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

        emit LastTimestampUpdated(_lastTimestamp);
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

        if (ReClammMath.computeCenteredness(currentBalancesScaled18, currentVirtualBalances) < _MIN_POOL_CENTEREDNESS) {
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
    function _computeCurrentFourthRootPriceRatio(
        PriceRatioState memory priceRatioState
    ) internal view returns (uint256 currentFourthRootPriceRatio) {
        currentFourthRootPriceRatio = ReClammMath.computeFourthRootPriceRatio(
            block.timestamp.toUint32(),
            priceRatioState.startFourthRootPriceRatio,
            priceRatioState.endFourthRootPriceRatio,
            priceRatioState.priceRatioUpdateStartTime,
            priceRatioState.priceRatioUpdateEndTime
        );
    }

    /// @dev This function relies on the pool balance, which can be manipulated if the vault is unlocked.
    function _isPoolInRange() internal view onlyWhenVaultIsLocked returns (bool) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));

        return ReClammMath.isPoolInRange(balancesScaled18, _lastVirtualBalances, _centerednessMargin);
    }

    /// @dev Checks that the current balance ratio is within the initialization balance ratio tolerance.
    function _checkInitializationBalanceRatio(
        uint256[] memory balancesScaled18,
        uint256[] memory theoreticalRealBalances
    ) internal pure {
        uint256 realBalanceRatio = balancesScaled18[1].divDown(balancesScaled18[0]);
        uint256 theoreticalBalanceRatio = theoreticalRealBalances[1].divDown(theoreticalRealBalances[0]);

        uint256 ratioLowerBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 ratioUpperBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (realBalanceRatio < ratioLowerBound || realBalanceRatio > ratioUpperBound) {
            revert BalanceRatioExceedsTolerance();
        }
    }

    /// @dev Checks that the current price interval and spot price is within the initialization price range.
    function _checkInitializationPrices(
        uint256[] memory balancesScaled18,
        uint256[] memory virtualBalances
    ) internal view {
        // Compare current spot price with initialization target price.
        uint256 spotPrice = (balancesScaled18[1] + virtualBalances[1]).divDown(
            balancesScaled18[0] + virtualBalances[0]
        );
        _comparePrice(spotPrice, _INITIAL_TARGET_PRICE);

        uint256 currentInvariant = ReClammMath.computeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_DOWN);

        // Compare current min price with initialization min price.
        uint256 currentMinPrice = (virtualBalances[1] * virtualBalances[1]) / currentInvariant;
        _comparePrice(currentMinPrice, _INITIAL_MIN_PRICE);

        // Compare current max price with initialization max price.
        uint256 currentMaxPrice = currentInvariant.divDown(virtualBalances[0]).divDown(virtualBalances[0]);
        _comparePrice(currentMaxPrice, _INITIAL_MAX_PRICE);
    }

    function _comparePrice(uint256 currentPrice, uint256 initializationPrice) internal pure {
        uint256 priceLowerBound = initializationPrice.mulDown(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 priceUpperBound = initializationPrice.mulDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (currentPrice < priceLowerBound || currentPrice > priceUpperBound) {
            revert WrongInitializationPrices();
        }
    }
}
