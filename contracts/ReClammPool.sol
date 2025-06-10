// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolAuthentication } from "@balancer-labs/v3-pool-utils/contracts/BasePoolAuthentication.sol";
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import { PriceRatioState, ReClammMath, a, b } from "./lib/ReClammMath.sol";
import {
    ReClammPoolParams,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData,
    IReClammPool
} from "./interfaces/IReClammPool.sol";

contract ReClammPool is IReClammPool, BalancerPoolToken, PoolInfo, BasePoolAuthentication, Version, BaseHooks {
    using FixedPoint for uint256;
    using ScalingHelpers for uint256;
    using SafeCast for *;
    using ReClammMath for *;

    // Fees are 18-decimal, floating point values, which will be stored in the Vault using 24 bits.
    // This means they have 0.00001% resolution (i.e., any non-zero bits < 1e11 will cause precision loss).
    // Minimum values help make the math well-behaved (i.e., the swap fee should overwhelm any rounding error).
    // Maximum values protect users by preventing permissioned actors from setting excessively high swap fees.
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // The daily price shift exponent is a percentage that defines the speed at which the virtual balances will change
    // over the course of one day. A value of 100% (i.e, FP 1) means that the min and max prices will double (or halve)
    // every day, until the pool price is within the range defined by the margin. This constant defines the maximum
    // "price shift" velocity.
    uint256 internal constant _MAX_DAILY_PRICE_SHIFT_EXPONENT = 300e16; // 300%

    // Price ratio updates must have both a minimum duration and a maximum daily rate. For instance, an update rate of
    // FP 2 means the ratio one day later must be at least half and at most double the rate at the start of the update.
    uint256 internal constant _MIN_PRICE_RATIO_UPDATE_DURATION = 1 days;
    uint256 internal immutable _MAX_DAILY_PRICE_RATIO_UPDATE_RATE;

    // There is also a minimum delta, to keep the math well-behaved.
    uint256 internal constant _MIN_PRICE_RATIO_DELTA = 1e6;

    uint256 internal constant _MAX_TOKEN_DECIMALS = 18;
    // This represents the maximum deviation from the ideal state (i.e., at target price and near centered) after
    // initialization, to prevent arbitration losses.
    uint256 internal constant _BALANCE_RATIO_AND_PRICE_TOLERANCE = 0.01e16; // 0.01%

    // These immutables are only used during initialization, to set the virtual balances and price ratio in a more
    // user-friendly manner.
    uint256 private immutable _INITIAL_MIN_PRICE;
    uint256 private immutable _INITIAL_MAX_PRICE;
    uint256 private immutable _INITIAL_TARGET_PRICE;
    uint256 private immutable _INITIAL_DAILY_PRICE_SHIFT_EXPONENT;
    uint256 private immutable _INITIAL_CENTEREDNESS_MARGIN;

    // ReClamm pools do not need to know the tokens on deployment. The factory deploys the pool, then registers it, at
    // which point the Vault knows the tokens and rate providers. Finally, the user initializes the pool through the
    // router, using the `computeInitialBalancesRaw` helper function to compute the correct initial raw balances.
    //
    // The twist here is that the pool may contain wrapped tokens (e.g., wstETH), and the initial prices given might be
    // in terms of either the wrapped or the underlying token. If the price is that of the actual token being supplied
    // (e.g., the wrapped token), the initialization helper should *not* apply the rate, and the flag should be false.
    // If the price is given in terms of the underlying token, the initialization helper *should* apply the rate, so
    // the flag should be true. Since the prices are stored on initialization, these flags are as well (vs. passing
    // them in at initialization time, when they might be out-of-sync with the prices).
    bool private immutable _TOKEN_A_PRICE_INCLUDES_RATE;
    bool private immutable _TOKEN_B_PRICE_INCLUDES_RATE;

    PriceRatioState internal _priceRatioState;

    // Timestamp of the last user interaction.
    uint32 internal _lastTimestamp;

    // Internal representation of the speed at which the pool moves the virtual balances when outside the target range.
    uint128 internal _dailyPriceShiftBase;

    // Used to define the target price range of the pool (i.e., where the pool centeredness >= centeredness margin).
    uint64 internal _centerednessMargin;

    // The virtual balances at the time of the last user interaction.
    uint128 internal _lastVirtualBalanceA;
    uint128 internal _lastVirtualBalanceB;

    // Protect functions that would otherwise be vulnerable to manipulation through transient liquidity.
    modifier onlyWhenVaultIsLocked() {
        _ensureVaultIsLocked();
        _;
    }

    function _ensureVaultIsLocked() internal view {
        if (_vault.isUnlocked()) {
            revert VaultIsNotLocked();
        }
    }

    modifier onlyWhenInitialized() {
        _ensureVaultIsInitialized();
        _;
    }

    function _ensureVaultIsInitialized() internal view {
        if (_vault.isPoolInitialized(address(this)) == false) {
            revert PoolNotInitialized();
        }
    }

    modifier onlyWithinTargetRange() {
        _ensurePoolWithinTargetRange();
        _;
        _ensurePoolWithinTargetRange();
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
        if (
            params.initialMinPrice == 0 ||
            params.initialMaxPrice == 0 ||
            params.initialTargetPrice == 0 ||
            params.initialTargetPrice < params.initialMinPrice ||
            params.initialTargetPrice > params.initialMaxPrice ||
            params.initialMinPrice >= params.initialMaxPrice
        ) {
            // If any of these prices were 0, pool initialization would revert with a numerical error.
            // For good measure, we also ensure the target is within the range.
            revert InvalidInitialPrice();
        }

        // Initialize immutable params. These are only used during pool initialization.
        _INITIAL_MIN_PRICE = params.initialMinPrice;
        _INITIAL_MAX_PRICE = params.initialMaxPrice;
        _INITIAL_TARGET_PRICE = params.initialTargetPrice;

        _INITIAL_DAILY_PRICE_SHIFT_EXPONENT = params.dailyPriceShiftExponent;
        _INITIAL_CENTEREDNESS_MARGIN = params.centerednessMargin;

        _TOKEN_A_PRICE_INCLUDES_RATE = params.tokenAPriceIncludesRate;
        _TOKEN_B_PRICE_INCLUDES_RATE = params.tokenBPriceIncludesRate;

        // The maximum daily price ratio change rate is given by 2^_MAX_DAILY_PRICE_SHIFT_EXPONENT.
        // This is somewhat arbitrary, but it makes sense to link these rates; i.e., we are setting the maximum speed
        // of expansion or contraction to equal the maximum speed of the price shift. It is expressed as a multiple;
        // i.e., 8e18 means it can change by 8x per day.
        _MAX_DAILY_PRICE_RATIO_UPDATE_RATE = FixedPoint.powUp(2e18, _MAX_DAILY_PRICE_SHIFT_EXPONENT);
    }

    /********************************************************
                    Base Pool Functions
    ********************************************************/

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balancesScaled18, Rounding rounding) public view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                _lastVirtualBalanceA,
                _lastVirtualBalanceB,
                _dailyPriceShiftBase,
                _lastTimestamp,
                _centerednessMargin,
                _priceRatioState,
                rounding
            );
    }

    /// @inheritdoc IBasePool
    function computeBalance(uint256[] memory, uint256, uint256) external pure returns (uint256) {
        // The pool does not allow unbalanced adds and removes, so this function does not need to be implemented.
        revert NotImplemented();
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory request) public virtual onlyVault returns (uint256 amountCalculatedScaled18) {
        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = _computeCurrentVirtualBalances(
            request.balancesScaled18
        );

        if (changed) {
            _setLastVirtualBalances(currentVirtualBalanceA, currentVirtualBalanceB);
        }

        _updateTimestamp();

        // Calculate swap result.
        if (request.kind == SwapKind.EXACT_IN) {
            amountCalculatedScaled18 = ReClammMath.computeOutGivenIn(
                request.balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
            );
        } else {
            amountCalculatedScaled18 = ReClammMath.computeInGivenOut(
                request.balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
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
                        Hook Functions
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

    struct InitializeLocals {
        uint256 rateA;
        uint256 rateB;
        uint256 minPriceScaled18;
        uint256 maxPriceScaled18;
        uint256 targetPriceScaled18;
        uint256[] theoreticalBalances;
        uint256 theoreticalVirtualBalanceA;
        uint256 theoreticalVirtualBalanceB;
        uint256 priceRatio;
    }

    /// @inheritdoc IHooks
    function onBeforeInitialize(
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        InitializeLocals memory locals;
        (locals.rateA, locals.rateB) = _getTokenRates();

        (
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18
        ) = _getPriceSettingsAdjustedByRates(locals.rateA, locals.rateB);

        (
            locals.theoreticalBalances,
            locals.theoreticalVirtualBalanceA,
            locals.theoreticalVirtualBalanceB,
            locals.priceRatio
        ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18
        );

        _checkInitializationBalanceRatio(balancesScaled18, locals.theoreticalBalances);

        uint256 scale = balancesScaled18[a].divDown(locals.theoreticalBalances[a]);

        uint256 virtualBalanceA = locals.theoreticalVirtualBalanceA.mulDown(scale);
        uint256 virtualBalanceB = locals.theoreticalVirtualBalanceB.mulDown(scale);

        _checkInitializationPrices(
            balancesScaled18,
            locals.minPriceScaled18,
            locals.maxPriceScaled18,
            locals.targetPriceScaled18,
            virtualBalanceA,
            virtualBalanceB
        );

        _setLastVirtualBalances(virtualBalanceA, virtualBalanceB);
        _startPriceRatioUpdate(locals.priceRatio, block.timestamp, block.timestamp);
        // Set dynamic parameters.
        _setDailyPriceShiftExponent(_INITIAL_DAILY_PRICE_SHIFT_EXPONENT);
        _setCenterednessMargin(_INITIAL_CENTEREDNESS_MARGIN);
        _updateTimestamp();

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256 exactBptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        // This hook makes sure that the virtual balances are increased in the same proportion as the real balances
        // after adding liquidity. This is needed to keep the pool centeredness and price ratio constant.

        uint256 poolTotalSupply = _vault.totalSupply(pool);
        uint256 newPoolTotalSupply = exactBptAmountOut + poolTotalSupply;

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = _computeCurrentVirtualBalances(
            balancesScaled18
        );
        // When adding/removing liquidity, round down the virtual balances. This favors the vault in swap operations.
        // The virtual balances are not used in proportional add/remove calculations.
        currentVirtualBalanceA = (currentVirtualBalanceA * newPoolTotalSupply) / poolTotalSupply;
        currentVirtualBalanceB = (currentVirtualBalanceB * newPoolTotalSupply) / poolTotalSupply;
        _setLastVirtualBalances(currentVirtualBalanceA, currentVirtualBalanceB);
        _updateTimestamp();

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind,
        uint256 exactBptAmountIn,
        uint256[] memory,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        // This hook makes sure that the virtual balances are decreased in the same proportion as the real balances
        // after removing liquidity. This is needed to keep the pool centeredness and price ratio constant.

        uint256 poolTotalSupply = _vault.totalSupply(pool);
        uint256 bptDelta = poolTotalSupply - exactBptAmountIn;

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = _computeCurrentVirtualBalances(
            balancesScaled18
        );

        // When adding/removing liquidity, round down the virtual balances. This favors the vault in swap operations.
        // The virtual balances are not used in proportional add/remove calculations.
        currentVirtualBalanceA = (currentVirtualBalanceA * bptDelta) / poolTotalSupply;
        currentVirtualBalanceB = (currentVirtualBalanceB * bptDelta) / poolTotalSupply;

        _setLastVirtualBalances(currentVirtualBalanceA, currentVirtualBalanceB);
        _updateTimestamp();

        return true;
    }

    /********************************************************
                        Pool State Getters
    ********************************************************/

    /// @inheritdoc IReClammPool
    function computeInitialBalancesRaw(
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw) {
        IERC20[] memory tokens = _vault.getPoolTokens(address(this));

        (uint256 referenceTokenIdx, uint256 otherTokenIdx) = tokens[a] == referenceToken ? (a, b) : (b, a);

        if (referenceTokenIdx == b && referenceToken != tokens[b]) {
            revert IVaultErrors.InvalidToken();
        }

        (uint256 rateA, uint256 rateB) = _getTokenRates();
        uint256 balanceRatioScaled18 = _computeInitialBalanceRatioScaled18(rateA, rateB);
        (uint256 rateReferenceToken, uint256 rateOtherToken) = tokens[a] == referenceToken
            ? (rateA, rateB)
            : (rateB, rateA);

        uint8 decimalsReferenceToken = IERC20Metadata(address(tokens[referenceTokenIdx])).decimals();
        uint8 decimalsOtherToken = IERC20Metadata(address(tokens[otherTokenIdx])).decimals();

        uint256 referenceAmountInScaled18 = referenceAmountInRaw.toScaled18ApplyRateRoundDown(
            10 ** (_MAX_TOKEN_DECIMALS - decimalsReferenceToken),
            rateReferenceToken
        );

        // Since the ratio is defined as b/a, multiply if we're given a, and divide if we're given b.
        // If the theoretical virtual balances were a=50 and b=100, then the ratio would be 100/50 = 2.
        // If we're given 100 a tokens, b = a * 2 = 200. If we're given 200 b tokens, a = b / 2 = 100.
        initialBalancesRaw = new uint256[](2);
        initialBalancesRaw[referenceTokenIdx] = referenceAmountInRaw;

        function(uint256, uint256) pure returns (uint256) _mulOrDiv = referenceTokenIdx == a
            ? FixedPoint.mulDown
            : FixedPoint.divDown;
        initialBalancesRaw[otherTokenIdx] = _mulOrDiv(referenceAmountInScaled18, balanceRatioScaled18)
            .toRawUndoRateRoundDown(10 ** (_MAX_TOKEN_DECIMALS - decimalsOtherToken), rateOtherToken);
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPriceRange() external view returns (uint256 minPrice, uint256 maxPrice) {
        if (_vault.isPoolInitialized(address(this))) {
            (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
            (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = _computeCurrentVirtualBalances(balancesScaled18);

            (minPrice, maxPrice) = ReClammMath.computePriceRange(balancesScaled18, virtualBalanceA, virtualBalanceB);
        } else {
            minPrice = _INITIAL_MIN_PRICE;
            maxPrice = _INITIAL_MAX_PRICE;
        }
    }

    /// @inheritdoc IReClammPool
    function computeCurrentVirtualBalances()
        external
        view
        returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed)
    {
        (, currentVirtualBalanceA, currentVirtualBalanceB, changed) = _getRealAndVirtualBalances();
    }

    /// @inheritdoc IReClammPool
    function computeCurrentSpotPrice() external view returns (uint256) {
        (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,

        ) = _getRealAndVirtualBalances();

        return (balancesScaled18[b] + currentVirtualBalanceB).divDown(balancesScaled18[a] + currentVirtualBalanceA);
    }

    function _getRealAndVirtualBalances()
        internal
        view
        returns (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,
            bool changed
        )
    {
        (, , , balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = _computeCurrentVirtualBalances(balancesScaled18);
    }

    /// @inheritdoc IReClammPool
    function getLastTimestamp() external view returns (uint32) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPool
    function getLastVirtualBalances() external view returns (uint256 virtualBalanceA, uint256 virtualBalanceB) {
        return (_lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /// @inheritdoc IReClammPool
    function getCenterednessMargin() external view returns (uint256) {
        return _centerednessMargin;
    }

    /// @inheritdoc IReClammPool
    function getDailyPriceShiftExponent() external view returns (uint256) {
        return _dailyPriceShiftBase.toDailyPriceShiftExponent();
    }

    /// @inheritdoc IReClammPool
    function getDailyPriceShiftBase() external view returns (uint256) {
        return _dailyPriceShiftBase;
    }

    /// @inheritdoc IReClammPool
    function getPriceRatioState() external view returns (PriceRatioState memory) {
        return _priceRatioState;
    }

    /// @inheritdoc IReClammPool
    function computeCurrentFourthRootPriceRatio() external view returns (uint256) {
        return ReClammMath.fourthRootScaled18(_computeCurrentPriceRatio());
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPriceRatio() external view returns (uint256) {
        return _computeCurrentPriceRatio();
    }

    /// @inheritdoc IReClammPool
    function isPoolWithinTargetRange() external view returns (bool) {
        return _isPoolWithinTargetRange();
    }

    /// @inheritdoc IReClammPool
    function isPoolWithinTargetRangeUsingCurrentVirtualBalances()
        external
        view
        returns (bool isWithinTargetRange, bool virtualBalancesChanged)
    {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        uint256 currentVirtualBalanceA;
        uint256 currentVirtualBalanceB;

        (currentVirtualBalanceA, currentVirtualBalanceB, virtualBalancesChanged) = _computeCurrentVirtualBalances(
            balancesScaled18
        );

        isWithinTargetRange = ReClammMath.isPoolWithinTargetRange(
            balancesScaled18,
            currentVirtualBalanceA,
            currentVirtualBalanceB,
            _centerednessMargin
        );
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPoolCenteredness() external view returns (uint256, bool) {
        (, , , uint256[] memory currentBalancesScaled18) = _vault.getPoolTokenInfo(address(this));
        return ReClammMath.computeCenteredness(currentBalancesScaled18, _lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /// @inheritdoc IReClammPool
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data) {
        data.balancesLiveScaled18 = _vault.getCurrentLiveBalances(address(this));
        (, data.tokenRates) = _vault.getPoolTokenRates(address(this));
        data.staticSwapFeePercentage = _vault.getStaticSwapFeePercentage((address(this)));
        data.totalSupply = totalSupply();

        data.lastTimestamp = _lastTimestamp;
        data.lastVirtualBalances = _getLastVirtualBalances();
        data.dailyPriceShiftBase = _dailyPriceShiftBase;
        data.dailyPriceShiftExponent = data.dailyPriceShiftBase.toDailyPriceShiftExponent();
        data.centerednessMargin = _centerednessMargin;

        PriceRatioState memory state = _priceRatioState;
        data.startFourthRootPriceRatio = state.startFourthRootPriceRatio;
        data.endFourthRootPriceRatio = state.endFourthRootPriceRatio;
        data.priceRatioUpdateStartTime = state.priceRatioUpdateStartTime;
        data.priceRatioUpdateEndTime = state.priceRatioUpdateEndTime;

        PoolConfig memory poolConfig = _vault.getPoolConfig(address(this));
        data.isPoolInitialized = poolConfig.isPoolInitialized;
        data.isPoolPaused = poolConfig.isPoolPaused;
        data.isPoolInRecoveryMode = poolConfig.isPoolInRecoveryMode;

        // If the pool is not initialized, virtual balances will be zero and `_computeCurrentPriceRatio` would revert.
        if (data.isPoolInitialized) {
            data.currentPriceRatio = _computeCurrentPriceRatio();
            data.currentFourthRootPriceRatio = ReClammMath.fourthRootScaled18(data.currentPriceRatio);
        }
    }

    /// @inheritdoc IReClammPool
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data) {
        // Base Pool
        data.tokens = _vault.getPoolTokens(address(this));
        (data.decimalScalingFactors, ) = _vault.getPoolTokenRates(address(this));
        data.tokenAPriceIncludesRate = _TOKEN_A_PRICE_INCLUDES_RATE;
        data.tokenBPriceIncludesRate = _TOKEN_B_PRICE_INCLUDES_RATE;
        data.minSwapFeePercentage = _MIN_SWAP_FEE_PERCENTAGE;
        data.maxSwapFeePercentage = _MAX_SWAP_FEE_PERCENTAGE;

        // Initialization
        data.initialMinPrice = _INITIAL_MIN_PRICE;
        data.initialMaxPrice = _INITIAL_MAX_PRICE;
        data.initialTargetPrice = _INITIAL_TARGET_PRICE;
        data.initialDailyPriceShiftExponent = _INITIAL_DAILY_PRICE_SHIFT_EXPONENT;
        data.initialCenterednessMargin = _INITIAL_CENTEREDNESS_MARGIN;

        // Operating Limits
        data.maxDailyPriceShiftExponent = _MAX_DAILY_PRICE_SHIFT_EXPONENT;
        data.maxDailyPriceRatioUpdateRate = _MAX_DAILY_PRICE_RATIO_UPDATE_RATE;
        data.minPriceRatioUpdateDuration = _MIN_PRICE_RATIO_UPDATE_DURATION;
        data.minPriceRatioDelta = _MIN_PRICE_RATIO_DELTA;
        data.balanceRatioAndPriceTolerance = _BALANCE_RATIO_AND_PRICE_TOLERANCE;
    }

    /********************************************************   
                        Pool State Setters
    ********************************************************/

    /// @inheritdoc IReClammPool
    function startPriceRatioUpdate(
        uint256 endPriceRatio,
        uint256 priceRatioUpdateStartTime,
        uint256 priceRatioUpdateEndTime
    )
        external
        onlyWhenInitialized
        onlySwapFeeManagerOrGovernance(address(this))
        returns (uint256 actualPriceRatioUpdateStartTime)
    {
        actualPriceRatioUpdateStartTime = GradualValueChange.resolveStartTime(
            priceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        uint256 updateDuration = priceRatioUpdateEndTime - actualPriceRatioUpdateStartTime;

        // We've already validated that end time >= start time at this point.
        if (updateDuration < _MIN_PRICE_RATIO_UPDATE_DURATION) {
            revert PriceRatioUpdateDurationTooShort();
        }

        _updateVirtualBalances();

        uint256 startPriceRatio = _startPriceRatioUpdate(
            endPriceRatio,
            actualPriceRatioUpdateStartTime,
            priceRatioUpdateEndTime
        );

        uint256 priceRatioDelta = endPriceRatio >= startPriceRatio
            ? endPriceRatio - startPriceRatio
            : startPriceRatio - endPriceRatio;

        if (priceRatioDelta < _MIN_PRICE_RATIO_DELTA) {
            revert PriceRatioDeltaBelowMin(priceRatioDelta);
        }

        // Compute the rate of change, as a multiple of the present value per day. For example, if the initial price
        // range was 1,000 - 4,000, with a target price of 2,000, the raw ratio would be 4 (`startPriceRatio` ~ 1.414).
        // If the new fourth root is 1.682, the new `endPriceRatio` would be 1.682^4 ~ 8. Note that since the
        // centeredness remains constant, the new range would NOT be 1,000 - 8,000, but [C / sqrt(8), C * sqrt(8)],
        // or about 707 - 5657.
        //
        // If the `updateDuration is 1 day, the time periods cancel, so `actualDailyPriceRatioUpdateRate` is simply
        // given by: `endPriceRatio` / `startPriceRatio`; or 8 / 4 = 2: doubling once per day.
        // All values are 18-decimal fixed point.
        uint256 actualDailyPriceRatioUpdateRate = endPriceRatio > startPriceRatio
            ? FixedPoint.divUp(endPriceRatio * 1 days, startPriceRatio * updateDuration)
            : FixedPoint.divUp(startPriceRatio * 1 days, endPriceRatio * updateDuration);

        if (actualDailyPriceRatioUpdateRate > _MAX_DAILY_PRICE_RATIO_UPDATE_RATE) {
            revert PriceRatioUpdateTooFast();
        }
    }

    /// @inheritdoc IReClammPool
    function stopPriceRatioUpdate() external onlyWhenInitialized onlySwapFeeManagerOrGovernance(address(this)) {
        _updateVirtualBalances();

        PriceRatioState memory priceRatioState = _priceRatioState;
        if (priceRatioState.priceRatioUpdateEndTime < block.timestamp) {
            revert PriceRatioNotUpdating();
        }

        uint256 currentPriceRatio = _computeCurrentPriceRatio();

        _startPriceRatioUpdate(currentPriceRatio, block.timestamp, block.timestamp);
    }

    /// @inheritdoc IReClammPool
    function setDailyPriceShiftExponent(
        uint256 newDailyPriceShiftExponent
    )
        external
        onlyWhenInitialized
        onlyWhenVaultIsLocked
        onlySwapFeeManagerOrGovernance(address(this))
        returns (uint256)
    {
        // Update virtual balances before updating the daily price shift exponent.
        return _setDailyPriceShiftExponentAndUpdateVirtualBalances(newDailyPriceShiftExponent);
    }

    /// @inheritdoc IReClammPool
    function setCenterednessMargin(
        uint256 newCenterednessMargin
    )
        external
        onlyWhenInitialized
        onlyWhenVaultIsLocked
        onlyWithinTargetRange
        onlySwapFeeManagerOrGovernance(address(this))
    {
        _setCenterednessMarginAndUpdateVirtualBalances(newCenterednessMargin);
    }

    /********************************************************
                        Internal Helpers
    ********************************************************/

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

    function _setLastVirtualBalances(uint256 virtualBalanceA, uint256 virtualBalanceB) internal {
        _lastVirtualBalanceA = virtualBalanceA.toUint128();
        _lastVirtualBalanceB = virtualBalanceB.toUint128();

        emit VirtualBalancesUpdated(virtualBalanceA, virtualBalanceB);

        _vault.emitAuxiliaryEvent("VirtualBalancesUpdated", abi.encode(virtualBalanceA, virtualBalanceB));
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
        if (_vault.isPoolInitialized(address(this))) {
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

        _vault.emitAuxiliaryEvent(
            "PriceRatioStateUpdated",
            abi.encode(
                startFourthRootPriceRatio,
                endFourthRootPriceRatio,
                priceRatioUpdateStartTime,
                priceRatioUpdateEndTime
            )
        );
    }

    /// Using the pool balances to update the virtual balances is dangerous with an unlocked vault, since the balances
    /// are manipulable.
    function _setDailyPriceShiftExponentAndUpdateVirtualBalances(
        uint256 dailyPriceShiftExponent
    ) internal returns (uint256) {
        // Update virtual balances with current daily price shift exponent.
        _updateVirtualBalances();

        // Update the price shift exponent.
        return _setDailyPriceShiftExponent(dailyPriceShiftExponent);
    }

    function _setDailyPriceShiftExponent(uint256 dailyPriceShiftExponent) internal returns (uint256) {
        if (dailyPriceShiftExponent > _MAX_DAILY_PRICE_SHIFT_EXPONENT) {
            revert DailyPriceShiftExponentTooHigh();
        }

        uint256 dailyPriceShiftBase = dailyPriceShiftExponent.toDailyPriceShiftBase();
        // There might be precision loss when adjusting to the internal representation, so we need to
        // convert back to the external representation to emit the event.
        dailyPriceShiftExponent = dailyPriceShiftBase.toDailyPriceShiftExponent();

        _dailyPriceShiftBase = dailyPriceShiftBase.toUint128();

        emit DailyPriceShiftExponentUpdated(dailyPriceShiftExponent, dailyPriceShiftBase);

        _vault.emitAuxiliaryEvent(
            "DailyPriceShiftExponentUpdated",
            abi.encode(dailyPriceShiftExponent, dailyPriceShiftBase)
        );

        return dailyPriceShiftExponent;
    }

    /**
     * @dev This function relies on the pool balance, which can be manipulated if the vault is unlocked. Also, the pool
     * must be within the target range before and after the operation, or the pool owner could arb the pool.
     */
    function _setCenterednessMarginAndUpdateVirtualBalances(uint256 centerednessMargin) internal {
        // Update the virtual balances using the current daily price shift exponent.
        _updateVirtualBalances();

        _setCenterednessMargin(centerednessMargin);
    }

    /**
     * @notice Sets the centeredness margin when the pool is created.
     * @param centerednessMargin The new centerednessMargin value, which must be within the target range
     */
    function _setCenterednessMargin(uint256 centerednessMargin) internal {
        if (centerednessMargin > FixedPoint.ONE) {
            revert InvalidCenterednessMargin();
        }

        // Straight cast is safe since the margin is validated above (and tests ensure the margins fit in uint64).
        _centerednessMargin = uint64(centerednessMargin);

        emit CenterednessMarginUpdated(centerednessMargin);

        _vault.emitAuxiliaryEvent("CenterednessMarginUpdated", abi.encode(centerednessMargin));
    }

    function _updateVirtualBalances() internal {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed) = _computeCurrentVirtualBalances(
            balancesScaled18
        );
        if (changed) {
            _setLastVirtualBalances(currentVirtualBalanceA, currentVirtualBalanceB);
        }

        _updateTimestamp();
    }

    // Updates the last timestamp to the current timestamp.
    function _updateTimestamp() internal {
        uint32 lastTimestamp32 = block.timestamp.toUint32();
        _lastTimestamp = lastTimestamp32;

        emit LastTimestampUpdated(lastTimestamp32);

        _vault.emitAuxiliaryEvent("LastTimestampUpdated", abi.encode(lastTimestamp32));
    }

    /**
     * @notice Computes the fourth root of the current price ratio.
     * @dev The function calculates the price ratio between tokens A and B using their real and virtual balances,
     * then takes the fourth root of this ratio. The multiplication by FixedPoint.ONE before each sqrt operation
     * is done to maintain precision in the fixed-point calculations.
     *
     * @return The fourth root of the current price ratio, maintaining precision through fixed-point arithmetic
     */
    function _computeCurrentPriceRatio() internal view returns (uint256) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));
        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = _computeCurrentVirtualBalances(balancesScaled18);

        return ReClammMath.computePriceRatio(balancesScaled18, virtualBalanceA, virtualBalanceB);
    }

    /// @dev This function relies on the pool balance, which can be manipulated if the vault is unlocked.
    function _isPoolWithinTargetRange() internal view returns (bool) {
        (, , , uint256[] memory balancesScaled18) = _vault.getPoolTokenInfo(address(this));

        return
            ReClammMath.isPoolWithinTargetRange(
                balancesScaled18,
                _lastVirtualBalanceA,
                _lastVirtualBalanceB,
                _centerednessMargin
            );
    }

    /// @dev Checks that the current balance ratio is within the initialization balance ratio tolerance.
    function _checkInitializationBalanceRatio(
        uint256[] memory balancesScaled18,
        uint256[] memory theoreticalBalances
    ) internal pure {
        uint256 realBalanceRatio = balancesScaled18[b].divDown(balancesScaled18[a]);
        uint256 theoreticalBalanceRatio = theoreticalBalances[b].divDown(theoreticalBalances[a]);

        uint256 ratioLowerBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 ratioUpperBound = theoreticalBalanceRatio.mulDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (realBalanceRatio < ratioLowerBound || realBalanceRatio > ratioUpperBound) {
            revert BalanceRatioExceedsTolerance();
        }
    }

    /**
     * @dev Checks that the current spot price is within the initialization tolerance of the price target, and that
     * the total price range after initialization (i.e., with real balances) corresponds closely enough to the desired
     * initial price range set on deployment.
     */
    function _checkInitializationPrices(
        uint256[] memory balancesScaled18,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 targetPrice,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal pure {
        // Compare current spot price with initialization target price.
        uint256 spotPrice = (balancesScaled18[b] + virtualBalanceB).divDown(balancesScaled18[a] + virtualBalanceA);
        _comparePrice(spotPrice, targetPrice);

        uint256 currentInvariant = ReClammMath.computeInvariant(
            balancesScaled18,
            virtualBalanceA,
            virtualBalanceB,
            Rounding.ROUND_DOWN
        );

        // Compare current min price with initialization min price.
        uint256 currentMinPrice = (virtualBalanceB * virtualBalanceB) / currentInvariant;
        _comparePrice(currentMinPrice, minPrice);

        // Compare current max price with initialization max price.
        uint256 currentMaxPrice = _computeMaxPrice(currentInvariant, virtualBalanceA);
        _comparePrice(currentMaxPrice, maxPrice);
    }

    function _comparePrice(uint256 currentPrice, uint256 initializationPrice) internal pure {
        uint256 priceLowerBound = initializationPrice.mulDown(FixedPoint.ONE - _BALANCE_RATIO_AND_PRICE_TOLERANCE);
        uint256 priceUpperBound = initializationPrice.mulDown(FixedPoint.ONE + _BALANCE_RATIO_AND_PRICE_TOLERANCE);

        if (currentPrice < priceLowerBound || currentPrice > priceUpperBound) {
            revert WrongInitializationPrices();
        }
    }

    function _getLastVirtualBalances() internal view returns (uint256[] memory) {
        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[a] = _lastVirtualBalanceA;
        lastVirtualBalances[b] = _lastVirtualBalanceB;

        return lastVirtualBalances;
    }

    function _ensurePoolWithinTargetRange() internal view {
        if (_isPoolWithinTargetRange() == false) {
            revert PoolOutsideTargetRange();
        }
    }

    function _computeInitialBalanceRatioScaled18(uint256 rateA, uint256 rateB) internal view returns (uint256) {
        (
            uint256 minPriceScaled18,
            uint256 maxPriceScaled18,
            uint256 targetPriceScaled18
        ) = _getPriceSettingsAdjustedByRates(rateA, rateB);

        (uint256[] memory theoreticalBalancesScaled18, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            minPriceScaled18,
            maxPriceScaled18,
            targetPriceScaled18
        );

        return theoreticalBalancesScaled18[b].divDown(theoreticalBalancesScaled18[a]);
    }

    function _computeMaxPrice(uint256 currentInvariant, uint256 virtualBalanceA) internal pure returns (uint256) {
        return currentInvariant.divDown(virtualBalanceA.mulDown(virtualBalanceA));
    }

    function _getTokenRates() internal view returns (uint256 rateA, uint256 rateB) {
        (, TokenInfo[] memory tokenInfo, , ) = _vault.getPoolTokenInfo(address(this));

        rateA = _getTokenRate(tokenInfo[a]);
        rateB = _getTokenRate(tokenInfo[b]);
    }

    function _getTokenRate(TokenInfo memory tokenInfo) internal view returns (uint256) {
        return tokenInfo.tokenType == TokenType.WITH_RATE ? tokenInfo.rateProvider.getRate() : FixedPoint.ONE;
    }

    function _getPriceSettingsAdjustedByRates(
        uint256 rateA,
        uint256 rateB
    ) internal view returns (uint256 minPrice, uint256 maxPrice, uint256 targetPrice) {
        rateA = _TOKEN_A_PRICE_INCLUDES_RATE ? rateA : FixedPoint.ONE;
        rateB = _TOKEN_B_PRICE_INCLUDES_RATE ? rateB : FixedPoint.ONE;

        // Example: a pool waUSDC/waWETH, where the price is given in terms of the underlying tokens.
        // Consider a USDC/ETH pool where the price is 2000. Token A is ETH (waWETH); token B is USDC (waUSDC).
        // If waUSDC has a rate of 2 (1 waUSDC = 2 USDC), the price of waUSDC/ETH is 1000, which is
        // obtained by dividing the price by the rate of waUSDC, which is token B.
        // Now, if the rate of waWETH is 1.5 (1 waWETH = 1.5 ETH), waUSDC/waWETH = 1500, which is
        // obtained by multiplying the price by the rate of waWETH, which is token A.
        minPrice = (_INITIAL_MIN_PRICE * rateA) / rateB;
        maxPrice = (_INITIAL_MAX_PRICE * rateA) / rateB;
        targetPrice = (_INITIAL_TARGET_PRICE * rateA) / rateB;
    }
}
