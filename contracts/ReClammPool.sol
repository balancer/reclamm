// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";

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

import { IReClammPoolExtension } from "./interfaces/IReClammPoolExtension.sol";
import { PriceRatioState, ReClammMath, a, b } from "./lib/ReClammMath.sol";
import { IReClammPoolMain } from "./interfaces/IReClammPoolMain.sol";
import { ReClammPoolParams } from "./interfaces/IReClammPool.sol";
import { ReClammCommon } from "./ReClammCommon.sol";

contract ReClammPool is
    IReClammPoolMain,
    BalancerPoolToken,
    PoolInfo,
    BasePoolAuthentication,
    Version,
    BaseHooks,
    ReClammCommon,
    Proxy
{
    using FixedPoint for uint256;
    using ScalingHelpers for uint256;
    using SafeCast for *;
    using ReClammMath for *;

    IReClammPoolExtension private immutable _RECLAMM_EXTENSION;

    error WrongReClammPoolExtensionDeployment();

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

    modifier onlyWithHookContract() {
        _ensureHookContract();
        _;
    }

    function _ensureHookContract() internal view {
        if (_HOOK_CONTRACT == address(0)) {
            // Should not happen. Hook flags would not go beyond ReClamm-required ones without a contract.
            revert NotImplemented();
        }
    }

    modifier onlyWithinTargetRange() {
        _ensurePoolWithinTargetRange();
        _;
        _ensurePoolWithinTargetRange();
    }

    modifier onlyWhenInitialized() {
        _ensureVaultIsInitialized();
        _;
    }

    function _ensureVaultIsInitialized() internal view {
        if (_getBalancerVault().isPoolInitialized(address(this)) == false) {
            revert PoolNotInitialized();
        }
    }

    constructor(
        ReClammPoolParams memory params,
        IVault vault,
        IReClammPoolExtension reclammPoolExtension,
        address hookContract
    )
        BalancerPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        BasePoolAuthentication(vault, msg.sender)
        Version(params.version)
    {
        if (address(reclammPoolExtension.pool()) != address(this)) {
            revert WrongReClammPoolExtensionDeployment();
        }

        _RECLAMM_EXTENSION = reclammPoolExtension;

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

        _HOOK_CONTRACT = hookContract;
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
    function getHookFlags() public view override returns (HookFlags memory hookFlags) {
        if (_HOOK_CONTRACT != address(0)) {
            // The hook contract may include hooks the native ReClamm pool does not.
            hookFlags = IHooks(_HOOK_CONTRACT).getHookFlags();
        }

        // Always set the hooks required by ReClamm.
        hookFlags.shouldCallBeforeInitialize = true;
        hookFlags.shouldCallBeforeAddLiquidity = true;
        hookFlags.shouldCallBeforeRemoveLiquidity = true;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address factory,
        address pool,
        TokenConfig[] memory tokenConfig,
        LiquidityManagement calldata liquidityManagement
    ) public override onlyVault returns (bool success) {
        success =
            tokenConfig.length == 2 &&
            liquidityManagement.disableUnbalancedLiquidity &&
            liquidityManagement.enableDonation == false;

        if (success && _HOOK_CONTRACT != address(0)) {
            success = IHooks(_HOOK_CONTRACT).onRegister(factory, pool, tokenConfig, liquidityManagement);
        }
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
        bytes memory userData
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

        return
            _HOOK_CONTRACT == address(0) ? true : IHooks(_HOOK_CONTRACT).onBeforeInitialize(balancesScaled18, userData);
    }

    /// @inheritdoc IHooks
    function onAfterInitialize(
        uint256[] memory exactAmountsIn,
        uint256 bptAmountOut,
        bytes memory userData
    ) public override onlyVault onlyWithHookContract returns (bool) {
        return IHooks(_HOOK_CONTRACT).onAfterInitialize(exactAmountsIn, bptAmountOut, userData);
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address router,
        address pool,
        AddLiquidityKind kind,
        uint256[] memory maxAmountsInScaled18,
        uint256 exactBptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory userData
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

        return
            _HOOK_CONTRACT == address(0)
                ? true
                : IHooks(_HOOK_CONTRACT).onBeforeAddLiquidity(
                    router,
                    pool,
                    kind,
                    maxAmountsInScaled18,
                    exactBptAmountOut,
                    balancesScaled18,
                    userData
                );
    }

    /// @inheritdoc IHooks
    function onAfterAddLiquidity(
        address router,
        address pool,
        AddLiquidityKind kind,
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256 bptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory userData
    ) public override onlyVault onlyWithHookContract returns (bool, uint256[] memory) {
        return
            IHooks(_HOOK_CONTRACT).onAfterAddLiquidity(
                router,
                pool,
                kind,
                amountsInScaled18,
                amountsInRaw,
                bptAmountOut,
                balancesScaled18,
                userData
            );
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address router,
        address pool,
        RemoveLiquidityKind kind,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOutScaled18,
        uint256[] memory balancesScaled18,
        bytes memory userData
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

        return
            _HOOK_CONTRACT == address(0)
                ? true
                : IHooks(_HOOK_CONTRACT).onBeforeRemoveLiquidity(
                    router,
                    pool,
                    kind,
                    exactBptAmountIn,
                    minAmountsOutScaled18,
                    balancesScaled18,
                    userData
                );
    }

    /// @inheritdoc IHooks
    function onAfterRemoveLiquidity(
        address router,
        address pool,
        RemoveLiquidityKind kind,
        uint256 bptAmountIn,
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory balancesScaled18,
        bytes memory userData
    ) public override onlyVault onlyWithHookContract returns (bool, uint256[] memory) {
        return
            IHooks(_HOOK_CONTRACT).onAfterRemoveLiquidity(
                router,
                pool,
                kind,
                bptAmountIn,
                amountsOutScaled18,
                amountsOutRaw,
                balancesScaled18,
                userData
            );
    }

    /// @inheritdoc IHooks
    function onBeforeSwap(
        PoolSwapParams calldata params,
        address pool
    ) public override onlyVault onlyWithHookContract returns (bool) {
        return IHooks(_HOOK_CONTRACT).onBeforeSwap(params, pool);
    }

    /// @inheritdoc IHooks
    function onAfterSwap(
        AfterSwapParams calldata params
    ) public override onlyVault onlyWithHookContract returns (bool, uint256) {
        return IHooks(_HOOK_CONTRACT).onAfterSwap(params);
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 staticSwapFeePercentage
    ) public view override onlyWithHookContract returns (bool, uint256) {
        // This does not need onlyVault, as it's defined as a view function in the interface.
        return IHooks(_HOOK_CONTRACT).onComputeDynamicSwapFeePercentage(params, pool, staticSwapFeePercentage);
    }

    /********************************************************
                        Pool State Getters
    ********************************************************/

    /// @inheritdoc IReClammPoolMain
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

    /// @inheritdoc IReClammPoolMain
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

    /// @inheritdoc IReClammPoolMain
    function computeCurrentVirtualBalances()
        external
        view
        returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed)
    {
        (, currentVirtualBalanceA, currentVirtualBalanceB, changed) = _getRealAndVirtualBalances();
    }

    /// @inheritdoc IReClammPoolMain
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

    /// @inheritdoc IReClammPoolMain
    function getLastTimestamp() external view returns (uint32) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPoolMain
    function getLastVirtualBalances() external view returns (uint256 virtualBalanceA, uint256 virtualBalanceB) {
        return (_lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /// @inheritdoc IReClammPoolMain
    function getCenterednessMargin() external view returns (uint256) {
        return _centerednessMargin;
    }

    /// @inheritdoc IReClammPoolMain
    function getDailyPriceShiftExponent() external view returns (uint256) {
        return _dailyPriceShiftBase.toDailyPriceShiftExponent();
    }

    /// @inheritdoc IReClammPoolMain
    function getDailyPriceShiftBase() external view returns (uint256) {
        return _dailyPriceShiftBase;
    }

    /// @inheritdoc IReClammPoolMain
    function getPriceRatioState() external view returns (PriceRatioState memory) {
        return _priceRatioState;
    }

    /// @inheritdoc IReClammPoolMain
    function isPoolWithinTargetRange() external view returns (bool) {
        return _isPoolWithinTargetRange();
    }

    /// @inheritdoc IReClammPoolMain
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

    /// @inheritdoc IReClammPoolMain
    function computeCurrentPoolCenteredness() external view returns (uint256, bool) {
        (, , , uint256[] memory currentBalancesScaled18) = _vault.getPoolTokenInfo(address(this));
        return ReClammMath.computeCenteredness(currentBalancesScaled18, _lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /********************************************************   
                        Pool State Setters
    ********************************************************/

    /// @inheritdoc IReClammPoolMain
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

    /// @inheritdoc IReClammPoolMain
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

    function _setLastVirtualBalances(uint256 virtualBalanceA, uint256 virtualBalanceB) internal {
        _lastVirtualBalanceA = virtualBalanceA.toUint128();
        _lastVirtualBalanceB = virtualBalanceB.toUint128();

        emit VirtualBalancesUpdated(virtualBalanceA, virtualBalanceB);

        _vault.emitAuxiliaryEvent("VirtualBalancesUpdated", abi.encode(virtualBalanceA, virtualBalanceB));
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
        if (centerednessMargin > _MAX_CENTEREDNESS_MARGIN) {
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
        rateA = _TOKEN_A_PRICE_INCLUDES_RATE ? FixedPoint.ONE : rateA;
        rateB = _TOKEN_B_PRICE_INCLUDES_RATE ? FixedPoint.ONE : rateB;

        // Example: a pool waUSDC/waWETH, where the price is given in terms of the underlying tokens.
        // Consider a USDC/ETH pool where the price is 2000. Token A is ETH (waWETH); token B is USDC (waUSDC).
        // If waUSDC has a rate of 2 (1 waUSDC = 2 USDC), the price of waUSDC/ETH is 1000, which is
        // obtained by dividing the price by the rate of waUSDC, which is token B.
        // Now, if the rate of waWETH is 1.5 (1 waWETH = 1.5 ETH), waUSDC/waWETH = 1500, which is
        // obtained by multiplying the price by the rate of waWETH, which is token A.
        // On the other hand, spot prices are computed using live balances which always contain the rates, so
        // we apply the inverse here (i.e. multiply by rate B, divide by rate A) to undo the effect.
        minPrice = (_INITIAL_MIN_PRICE * rateB) / rateA;
        maxPrice = (_INITIAL_MAX_PRICE * rateB) / rateA;
        targetPrice = (_INITIAL_TARGET_PRICE * rateB) / rateA;
    }

    /// @inheritdoc IReClammPoolMain
    function computeCurrentPriceRatio() external view returns (uint256) {
        return _computeCurrentPriceRatio();
    }

    /// @inheritdoc IReClammPoolMain
    function computeCurrentFourthRootPriceRatio() external view returns (uint256) {
        return ReClammMath.fourthRootScaled18(_computeCurrentPriceRatio());
    }

    /// @inheritdoc IReClammPoolMain
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

        uint256 priceRatioDelta;
        unchecked {
            priceRatioDelta = endPriceRatio >= startPriceRatio
                ? endPriceRatio - startPriceRatio
                : startPriceRatio - endPriceRatio;
        }

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

    /// @inheritdoc IReClammPoolMain
    function stopPriceRatioUpdate() external onlyWhenInitialized onlySwapFeeManagerOrGovernance(address(this)) {
        _updateVirtualBalances();

        PriceRatioState memory priceRatioState = _priceRatioState;
        if (priceRatioState.priceRatioUpdateEndTime < block.timestamp) {
            revert PriceRatioNotUpdating();
        }

        uint256 currentPriceRatio = _computeCurrentPriceRatio();

        _startPriceRatioUpdate(currentPriceRatio, block.timestamp, block.timestamp);
    }

    /*******************************************************************************
                                     Miscellaneous
    *******************************************************************************/

    /// @inheritdoc IReClammPoolMain
    function getReClammPoolExtension() external view returns (address) {
        return _implementation();
    }

    // For ReClammCommon Vault access.
    function _getBalancerVault() internal view override returns (IVault) {
        return _vault;
    }

    /**
     * @inheritdoc Proxy
     * @dev Returns the VaultExtension contract, to which fallback requests are forwarded.
     */
    function _implementation() internal view override returns (address) {
        return address(_RECLAMM_EXTENSION);
    }

    /*******************************************************************************
                                     Default handlers
    *******************************************************************************/

    receive() external payable {
        revert IVaultErrors.CannotReceiveEth();
    }

    // solhint-disable no-complex-fallback

    /**
     * @inheritdoc Proxy
     * @dev Override proxy implementation of `fallback` to disallow incoming ETH transfers.
     * This function actually returns whatever the ReClammPoolExtension does when handling the request.
     */
    fallback() external payable override {
        if (msg.value > 0) {
            revert IVaultErrors.CannotReceiveEth();
        }

        _fallback();
    }
}
