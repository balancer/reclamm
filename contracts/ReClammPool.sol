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
import { GradualValueChange } from "@balancer-labs/v3-pool-weighted/contracts/lib/GradualValueChange.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

import { PriceRatioState, ReClammMath, a, b } from "./lib/ReClammMath.sol";
import { ReClammPoolFactoryLib } from "./lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolHelper } from "./ReClammPoolHelper.sol";
import "./interfaces/IReClammPool.sol";

contract ReClammPool is IReClammPool, BalancerPoolToken, PoolInfo, BasePoolAuthentication, Version, BaseHooks {
    using FixedPoint for uint256;
    using ScalingHelpers for uint256;
    using SafeCast for *;
    using ReClammMath for *;

    // solhint-disable custom-errors

    // Fees are 18-decimal, floating point values, which will be stored in the Vault using 24 bits.
    // This means they have 0.00001% resolution (i.e., any non-zero bits < 1e11 will cause precision loss).
    // Minimum values help make the math well-behaved (i.e., the swap fee should overwhelm any rounding error).
    // Maximum values protect users by preventing permissioned actors from setting excessively high swap fees.
    // Note: the minimum swap fee also bounds the pool's resistance to round-trip repricing extraction.
    // At 0.001%, shift rates up to 5% are safe (47-second breakeven). See `setDailyPriceShiftExponent` for details.
    uint256 internal constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // Price ratio updates must have both a minimum duration and a maximum daily rate. For instance, an update rate of
    // FP 2 means the ratio one day later must be at least half and at most double the rate at the start of the update.
    uint256 internal constant _MIN_PRICE_RATIO_UPDATE_DURATION = 1 days;

    // There is also a minimum delta, to keep the math well-behaved.
    uint256 internal constant _MIN_PRICE_RATIO_DELTA = 1e6;

    // solhint-disable-next-line immutable-vars-naming
    ReClammPoolHelper internal immutable _helper;

    // Constant in the helper, cached here for convenience at construction time.
    uint256 private immutable _BALANCE_RATIO_AND_PRICE_TOLERANCE;

    // Price ratio updates must have a maximum daily rate. For instance, an update rate of FP 2 means the ratio one
    // day later must be at least half and at most double the rate at the start of the update.
    // This value is calculated at construction time based on `ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT`.
    uint256 internal immutable _MAX_DAILY_PRICE_RATIO_UPDATE_RATE;

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

    constructor(
        ReClammPoolParams memory params,
        IVault vault,
        ReClammPoolHelper helper
    )
        BalancerPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        BasePoolAuthentication(vault, msg.sender)
        Version(params.version)
    {
        _helper = helper;
        _BALANCE_RATIO_AND_PRICE_TOLERANCE = helper.BALANCE_RATIO_AND_PRICE_TOLERANCE();

        ReClammPoolFactoryLib.validatePoolParams(params);

        // Initialize immutable params. These are only used during pool initialization.
        _INITIAL_MIN_PRICE = params.initialMinPrice;
        _INITIAL_MAX_PRICE = params.initialMaxPrice;
        _INITIAL_TARGET_PRICE = params.initialTargetPrice;

        _INITIAL_DAILY_PRICE_SHIFT_EXPONENT = params.dailyPriceShiftExponent;
        _INITIAL_CENTEREDNESS_MARGIN = params.centerednessMargin;

        _TOKEN_A_PRICE_INCLUDES_RATE = params.tokenAPriceIncludesRate;
        _TOKEN_B_PRICE_INCLUDES_RATE = params.tokenBPriceIncludesRate;

        // The maximum daily price ratio change rate is 2^ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT.
        // This is somewhat arbitrary, but it makes sense to link these rates; i.e., we are setting the maximum speed
        // of expansion or contraction to equal the maximum speed of the price shift. It is expressed as a multiple;
        // i.e., 8e18 means it can change by 8x per day.
        _MAX_DAILY_PRICE_RATIO_UPDATE_RATE = FixedPoint.powUp(
            2e18,
            ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT
        );
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
        address pool,
        TokenConfig[] memory tokenConfig,
        LiquidityManagement calldata liquidityManagement
    ) public view override returns (bool) {
        // This function is `view`, so it does not need `onlyVault` protection.
        // Only returns `true` if invoked for this pool. This is important to prevent malicious pools from
        // registering these hooks, which gives them access to state modifying functions
        // (`onBeforeInitialize`, `onBeforeAddLiquidity`, and `onBeforeRemoveLiquidity`).
        return
            pool == address(this) &&
            tokenConfig.length == 2 &&
            liquidityManagement.disableUnbalancedLiquidity &&
            liquidityManagement.enableDonation == false;
    }

    /// @inheritdoc IHooks
    function onBeforeInitialize(
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        // There is no `pool` argument, but given that `onRegister` only allows this contract to register these hooks
        // for itself, `onlyVault` is sufficient. On the other hand, there is no reason to call this function
        // more than once, so we ensure that locally.
        if (_vault.isPoolInitialized(address(this))) {
            revert PoolAlreadyInitialized();
        }

        (uint256 virtualBalanceA, uint256 virtualBalanceB, uint256 priceRatio) = _helper
            .computeInitialVirtualBalancesAndRatio(balancesScaled18);

        // Defense-in-depth check: the factory's validateTargetPrice uses a closed-form sqrt-based approximation of
        // centeredness from the configured prices. This check uses the actual computed virtual balances and rate-
        // adjusted balances, so it catches any divergence due to rounding between the two formulas.
        (uint256 centeredness, ) = ReClammMath.computeCenteredness(balancesScaled18, virtualBalanceA, virtualBalanceB);
        if (centeredness < _INITIAL_CENTEREDNESS_MARGIN) {
            revert PoolOutsideTargetRange();
        }

        _setLastVirtualBalances(virtualBalanceA, virtualBalanceB);
        _startPriceRatioUpdate(priceRatio, block.timestamp, block.timestamp);
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
        // `onlyVault` is sufficient, but in any case this code should only be executed when the Vault calls this
        // function with the correct pool address.
        require(pool == address(this), InvalidPoolArgument(pool));

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
        // `onlyVault` is sufficient, but in any case this code should only be executed when the Vault calls this
        // function with the correct pool address.
        require(pool == address(this), InvalidPoolArgument(pool));

        // This hook makes sure that the virtual balances are decreased in the same proportion as the real balances
        // after removing liquidity. This is needed to keep the pool centeredness and price ratio constant.
        //
        // Note: when a proportional remove follows an add in the same transaction, the Vault charges a round-trip fee
        // on the remove outputs. This is an intentional Vault-level guardrail: adding and removing in the same session
        // is not something a legitimate user would normally do, and the fee helps ensure the round trip is not
        // profitable. This hook commits virtual balances before that fee is applied, so the stored VBs will be
        // slightly lower than a perfect proportional scaling of the post-fee real balances. The effect is small
        // (bounded by swapFeePercentage * proportionRemoved) and leaves the pool with slightly more real balance
        // relative to its virtual balances, marginally improving centeredness.

        uint256 poolTotalSupply = _vault.totalSupply(pool);
        uint256 bptDelta = poolTotalSupply - exactBptAmountIn;

        (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, ) = _computeCurrentVirtualBalances(
            balancesScaled18
        );

        // When adding/removing liquidity, round down the virtual balances. This favors the vault in swap operations.
        // The virtual balances are not used in proportional add/remove calculations.
        currentVirtualBalanceA = (currentVirtualBalanceA * bptDelta) / poolTotalSupply;
        currentVirtualBalanceB = (currentVirtualBalanceB * bptDelta) / poolTotalSupply;

        // Revert if the post-scaling virtual balances would be zero. This can only happen on a near-total proportional
        // burn by a sole (or effectively sole) LP, where `bptDelta` shrinks to `POOL_MINIMUM_TOTAL_SUPPLY` and the
        // multiplication above integer-truncates one of the virtual balances to zero. The math elsewhere is robust at
        // any positive virtual balance except exactly zero. In that case, `computePriceRatio` would fail with a
        // division by zero, and permanently brick the pool.
        if (currentVirtualBalanceA == 0 || currentVirtualBalanceB == 0) {
            revert ZeroVirtualBalance();
        }

        _setLastVirtualBalances(currentVirtualBalanceA, currentVirtualBalanceB);
        _updateTimestamp();

        return true;
    }

    /********************************************************
                       Stored State Getters
    ********************************************************/

    // The getters in this section return values directly from storage. They perform no virtual-balance math and are
    // safe to call before the pool has been initialized; they will simply return zero values for state that hasn't
    // been set yet.

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

    /********************************************************
                        Live State Getters
    ********************************************************/

    /// @inheritdoc IReClammPool
    function computeCurrentPriceRange() external view returns (uint256 minPrice, uint256 maxPrice) {
        if (_vault.isPoolInitialized(address(this))) {
            (
                uint256[] memory balancesScaled18,
                uint256 currentVirtualBalanceA,
                uint256 currentVirtualBalanceB,

            ) = _getRealAndVirtualBalances();

            (minPrice, maxPrice) = ReClammMath.computePriceRange(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB
            );
        } else {
            minPrice = _INITIAL_MIN_PRICE;
            maxPrice = _INITIAL_MAX_PRICE;
        }
    }

    /// @inheritdoc IReClammPool
    function computeCurrentVirtualBalances()
        external
        view
        onlyWhenInitialized
        returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed)
    {
        (, currentVirtualBalanceA, currentVirtualBalanceB, changed) = _getRealAndVirtualBalances();
    }

    /**
     * @notice Returns current live pool balances and time-adjusted virtual balances.
     * @dev Both balances and virtual balances are in the same underlying/rate-scaled space, which is required
     * for consistent spot price and price ratio calculations. State-mutating paths (onSwap, _updateVirtualBalances)
     * also operate on live balances, so this keeps the frames consistent.
     *
     * @return balancesScaled18 Current live balances, scaled to 18 decimals (decimal scaling and rates applied)
     * @return currentVirtualBalanceA Current virtual balance of token A, adjusted for time elapsed since last update
     * @return currentVirtualBalanceB Current virtual balance of token B, adjusted for time elapsed since last update
     * @return changed True if the virtual balances differ from `lastVirtualBalances`
     */
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
        balancesScaled18 = _vault.getCurrentLiveBalances(address(this));
        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = _computeCurrentVirtualBalances(balancesScaled18);
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPriceRatio() external view onlyWhenInitialized returns (uint256) {
        return _computeCurrentPriceRatio();
    }

    /// @inheritdoc IReClammPool
    function computeCurrentFourthRootPriceRatio() external view onlyWhenInitialized returns (uint256) {
        return ReClammMath.fourthRootScaled18(_computeCurrentPriceRatio());
    }

    /// @inheritdoc IReClammPool
    function computeCurrentPoolCenteredness() external view onlyWhenInitialized returns (uint256, bool) {
        (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,

        ) = _getRealAndVirtualBalances();

        return ReClammMath.computeCenteredness(balancesScaled18, currentVirtualBalanceA, currentVirtualBalanceB);
    }

    /// @inheritdoc IReClammPool
    function isPoolWithinTargetRange() external view onlyWhenInitialized returns (bool) {
        (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,

        ) = _getRealAndVirtualBalances();

        return
            ReClammMath.isPoolWithinTargetRange(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                _centerednessMargin
            );
    }

    /********************************************************
                        Off-chain Helpers
    ********************************************************/

    /// @inheritdoc IReClammPool
    function computeInitialBalancesRaw(
        IERC20 referenceToken,
        uint256 referenceAmountInRaw
    ) external view returns (uint256[] memory initialBalancesRaw) {
        return _helper.computeInitialBalancesRaw(this, referenceToken, referenceAmountInRaw);
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

        // The price ratio is derived from live + virtual balances; before initialization, virtual balances are zero
        // and `_computeCurrentPriceRatio` would revert (the public `computeCurrentPriceRatio` getter explicitly
        // reverts with `PoolNotInitialized` for the same reason). Skip the computation here so that integrations
        // can still call `getReClammPoolDynamicData` on a freshly deployed pool. The ratio fields stay zero, while
        // the static fields (rates, fees, supply) remain readable.
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
        data.minPriceRatio = ReClammPoolFactoryLib.MIN_PRICE_RATIO;
        data.maxPriceRatio = ReClammPoolFactoryLib.MAX_PRICE_RATIO;
        data.maxCenterednessMargin = ReClammPoolFactoryLib.MAX_CENTEREDNESS_MARGIN;
        data.maxDailyPriceShiftExponent = ReClammPoolFactoryLib.MAX_DAILY_PRICE_SHIFT_EXPONENT;
        data.maxDailyPriceRatioUpdateRate = _MAX_DAILY_PRICE_RATIO_UPDATE_RATE;
        data.minPriceRatioUpdateDuration = _MIN_PRICE_RATIO_UPDATE_DURATION;
        data.minPriceRatioDelta = _MIN_PRICE_RATIO_DELTA;
        data.balanceRatioAndPriceTolerance = _BALANCE_RATIO_AND_PRICE_TOLERANCE;
    }

    /********************************************************
                        Pool State Setters
    ********************************************************/

    // NOTE: `startPriceRatioUpdate` and `stopPriceRatioUpdate` intentionally omit `onlyWhenVaultIsLocked`.
    // See the interface NatSpec for the details.

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
        // Note: If the initial price range was 1,000 - 4,000, with a target price of 2,000, the raw ratio
        // is 4 (`startPriceRatio` ~ 1.414). If the new fourth root is 1.682, the new `endPriceRatio` is 1.682^4 ~ 8.
        // Since the centeredness remains constant, the new range would NOT be 1,000 - 8,000, but
        // [C / sqrt(8), C * sqrt(8)], or about 707 - 5657.

        if (endPriceRatio < ReClammPoolFactoryLib.MIN_PRICE_RATIO) {
            revert PriceRatioBelowMin(endPriceRatio);
        } else if (endPriceRatio > ReClammPoolFactoryLib.MAX_PRICE_RATIO) {
            revert PriceRatioAboveMax(endPriceRatio);
        }

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

        uint256 priceRatioDelta;
        unchecked {
            priceRatioDelta = endPriceRatio >= startPriceRatio
                ? endPriceRatio - startPriceRatio
                : startPriceRatio - endPriceRatio;
        }

        if (priceRatioDelta < _MIN_PRICE_RATIO_DELTA) {
            revert PriceRatioDeltaBelowMin(priceRatioDelta);
        }

        if (
            _computeDailyPriceRatioUpdateRate(startPriceRatio, endPriceRatio, updateDuration) >
            _MAX_DAILY_PRICE_RATIO_UPDATE_RATE
        ) {
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
        // NOTE: increasing the shift rate increases the pool's exposure to round-trip repricing extraction.
        // Ensure the swap fee is at least `shift_rate_pct * 0.0002%` to maintain a safe breakeven time.
        // See the interface NatSpec for the full analysis.
        return _setDailyPriceShiftExponentAndUpdateVirtualBalances(newDailyPriceShiftExponent);
    }

    /// @inheritdoc IReClammPool
    function setCenterednessMargin(
        uint256 newCenterednessMargin
    ) external onlyWhenInitialized onlyWhenVaultIsLocked onlySwapFeeManagerOrGovernance(address(this)) {
        uint256[] memory balancesScaled18 = _updateVirtualBalances();

        // Virtual balances are updated in the call above, so we can just read last virtual balances here.
        (uint256 centeredness, ) = ReClammMath.computeCenteredness(
            balancesScaled18,
            _lastVirtualBalanceA,
            _lastVirtualBalanceB
        );

        // The current margin must place the pool within the target range, to prevent setting a margin that would
        // immediately place the pool outside of the target range. This is important because an excessively high margin
        // could be used maliciously to manipulate the pool price by forcing it to stay within an excessively tight
        // range. The new margin must also not be higher than the current centeredness, to prevent similar manipulation.
        // It is possible to bypass this check with settled swaps before and after setting the new margin;
        // this is a best-effort check to prevent accidental misconfigurations.
        require(centeredness >= _centerednessMargin && centeredness >= newCenterednessMargin, PoolOutsideTargetRange());

        _setCenterednessMargin(newCenterednessMargin);
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

    /**
     * @notice Computes the effective daily price ratio update rate for a given start/end ratio and duration.
     * @dev The rate is exponential: `(max(end, start) / min(end, start))^(1 day / updateDuration)`.
     * All inputs and the return value are 18-decimal fixed point.
     *
     * @param startPriceRatio The price ratio at the start of the update
     * @param endPriceRatio The price ratio at the end of the update
     * @param updateDuration The duration of the update in seconds
     * @return The effective daily price ratio change factor (>= FP(1))
     */
    function _computeDailyPriceRatioUpdateRate(
        uint256 startPriceRatio,
        uint256 endPriceRatio,
        uint256 updateDuration
    ) internal pure returns (uint256) {
        uint256 priceRatioMultiple = endPriceRatio > startPriceRatio
            ? endPriceRatio.divUp(startPriceRatio)
            : startPriceRatio.divUp(endPriceRatio);
        uint256 exponent = FixedPoint.divUp(1 days, updateDuration);
        return priceRatioMultiple.powUp(exponent);
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
        ReClammPoolFactoryLib.validateDailyPriceShiftExponent(dailyPriceShiftExponent);

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
     * @notice Sets the centeredness margin when the pool is created.
     * @param centerednessMargin The new centerednessMargin value, which must be within the target range
     */
    function _setCenterednessMargin(uint256 centerednessMargin) internal {
        if (centerednessMargin > ReClammPoolFactoryLib.MAX_CENTEREDNESS_MARGIN) {
            revert InvalidCenterednessMargin();
        }

        // Straight cast is safe since the margin is validated above (and tests ensure the margins fit in uint64).
        _centerednessMargin = uint64(centerednessMargin);

        emit CenterednessMarginUpdated(centerednessMargin);

        _vault.emitAuxiliaryEvent("CenterednessMarginUpdated", abi.encode(centerednessMargin));
    }

    function _updateVirtualBalances() internal returns (uint256[] memory balancesScaled18) {
        uint256 currentVirtualBalanceA;
        uint256 currentVirtualBalanceB;
        bool changed;

        (balancesScaled18, currentVirtualBalanceA, currentVirtualBalanceB, changed) = _getRealAndVirtualBalances();

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
     * @notice Computes the current price ratio using live balances and time-adjusted virtual balances.
     * @return The current price ratio (maxPrice / minPrice) as an 18-decimal FP value
     */
    function _computeCurrentPriceRatio() internal view returns (uint256) {
        (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,

        ) = _getRealAndVirtualBalances();

        return ReClammMath.computePriceRatio(balancesScaled18, currentVirtualBalanceA, currentVirtualBalanceB);
    }

    function _getLastVirtualBalances() internal view returns (uint256[] memory) {
        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[a] = _lastVirtualBalanceA;
        lastVirtualBalances[b] = _lastVirtualBalanceB;

        return lastVirtualBalances;
    }
}
