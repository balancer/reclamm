// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { PoolConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";

import { ReClammMath, PriceRatioState, a, b } from "./lib/ReClammMath.sol";
import { ReClammPoolParams } from "./interfaces/IReClammPool.sol";
import { ReClammCommon } from "./ReClammCommon.sol";
import "./interfaces/IReClammPoolExtension.sol";

contract ReClammPoolExtension is IReClammPoolExtension, ReClammCommon, VaultGuard {
    using ReClammMath for *;
    using FixedPoint for uint256;

    IReClammPoolMain private immutable _POOL;

    IVault private immutable _VAULT;

    /**
     * @notice The `ReClammPoolExtension` contract was called by an account directly.
     * @dev It can only be called by a ReClammPool via delegate call.
     */
    error NotPoolDelegateCall();

    /// @dev Functions with this modifier can only be delegate-called by the Vault.
    modifier onlyPoolDelegateCall() {
        _ensurePoolDelegateCall();
        _;
    }

    /// @dev Can only call hook functions not defined by the main pool if the secondary hook implements them.
    modifier onlyWithHookContract() {
        _ensureHookContract();
        _;
    }

    constructor(
        IReClammPoolMain reclammPool,
        IVault vault,
        ReClammPoolParams memory params,
        address hookContract
    ) VaultGuard(vault) {
        _POOL = reclammPool;
        _VAULT = vault;

        // Need to initialize these the same as in ReClammPool.
        _INITIAL_MIN_PRICE = params.initialMinPrice;
        _INITIAL_MAX_PRICE = params.initialMaxPrice;
        _INITIAL_TARGET_PRICE = params.initialTargetPrice;

        _INITIAL_DAILY_PRICE_SHIFT_EXPONENT = params.dailyPriceShiftExponent;
        _INITIAL_CENTEREDNESS_MARGIN = params.centerednessMargin;

        _TOKEN_A_PRICE_INCLUDES_RATE = params.tokenAPriceIncludesRate;
        _TOKEN_B_PRICE_INCLUDES_RATE = params.tokenBPriceIncludesRate;

        _HOOK_CONTRACT = hookContract;
    }

    /*******************************************************************************
                                   Pool State Getters
    *******************************************************************************/

    /// @inheritdoc IReClammPoolExtension
    function getLastTimestamp() external view onlyPoolDelegateCall returns (uint32) {
        return _lastTimestamp;
    }

    /// @inheritdoc IReClammPoolExtension
    function getLastVirtualBalances()
        external
        view
        onlyPoolDelegateCall
        returns (uint256 virtualBalanceA, uint256 virtualBalanceB)
    {
        return (_lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /// @inheritdoc IReClammPoolExtension
    function getCenterednessMargin() external view onlyPoolDelegateCall returns (uint256) {
        return _centerednessMargin;
    }

    /// @inheritdoc IReClammPoolExtension
    function getDailyPriceShiftExponent() external view onlyPoolDelegateCall returns (uint256) {
        return _dailyPriceShiftBase.toDailyPriceShiftExponent();
    }

    /// @inheritdoc IReClammPoolExtension
    function getDailyPriceShiftBase() external view onlyPoolDelegateCall returns (uint256) {
        return _dailyPriceShiftBase;
    }

    /// @inheritdoc IReClammPoolExtension
    function getPriceRatioState() external view onlyPoolDelegateCall returns (PriceRatioState memory) {
        return _priceRatioState;
    }

    /// @inheritdoc IReClammPoolExtension
    function getReClammPoolDynamicData()
        external
        view
        onlyPoolDelegateCall
        returns (ReClammPoolDynamicData memory data)
    {
        data.balancesLiveScaled18 = _VAULT.getCurrentLiveBalances(address(this));
        (, data.tokenRates) = _VAULT.getPoolTokenRates(address(this));
        data.staticSwapFeePercentage = _VAULT.getStaticSwapFeePercentage((address(this)));
        data.totalSupply = _totalSupply();

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

        PoolConfig memory poolConfig = _VAULT.getPoolConfig(address(this));
        data.isPoolInitialized = poolConfig.isPoolInitialized;
        data.isPoolPaused = poolConfig.isPoolPaused;
        data.isPoolInRecoveryMode = poolConfig.isPoolInRecoveryMode;

        // If the pool is not initialized, virtual balances will be zero and `_computeCurrentPriceRatio` would revert.
        if (data.isPoolInitialized) {
            data.currentPriceRatio = _computeCurrentPriceRatio();
            data.currentFourthRootPriceRatio = ReClammMath.fourthRootScaled18(data.currentPriceRatio);
        }
    }

    /// @inheritdoc IReClammPoolExtension
    function getReClammPoolImmutableData()
        external
        view
        onlyPoolDelegateCall
        returns (ReClammPoolImmutableData memory data)
    {
        // Base Pool
        data.tokens = _VAULT.getPoolTokens(address(this));
        (data.decimalScalingFactors, ) = _VAULT.getPoolTokenRates(address(this));
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
        data.hookContract = _HOOK_CONTRACT;

        // Operating Limits
        data.maxCenterednessMargin = _MAX_CENTEREDNESS_MARGIN;
        data.maxDailyPriceShiftExponent = _MAX_DAILY_PRICE_SHIFT_EXPONENT;
        data.maxDailyPriceRatioUpdateRate = _MAX_DAILY_PRICE_RATIO_UPDATE_RATE;
        data.minPriceRatioUpdateDuration = _MIN_PRICE_RATIO_UPDATE_DURATION;
        data.minPriceRatioDelta = _MIN_PRICE_RATIO_DELTA;
        data.balanceRatioAndPriceTolerance = _BALANCE_RATIO_AND_PRICE_TOLERANCE;
    }

    /*******************************************************************************
                                Convenience Functions
    *******************************************************************************/
    
    /// @inheritdoc IReClammPoolExtension
    function computeCurrentPriceRatio() external view onlyPoolDelegateCall returns (uint256) {
        return _computeCurrentPriceRatio();
    }

    /// @inheritdoc IReClammPoolExtension
    function computeCurrentFourthRootPriceRatio() external view onlyPoolDelegateCall returns (uint256) {
        return ReClammMath.fourthRootScaled18(_computeCurrentPriceRatio());
    }

    /// @inheritdoc IReClammPoolExtension
    function computeCurrentPriceRange()
        external
        view
        onlyPoolDelegateCall
        returns (uint256 minPrice, uint256 maxPrice)
    {
        if (_VAULT.isPoolInitialized(address(this))) {
            (, , , uint256[] memory balancesScaled18) = _VAULT.getPoolTokenInfo(address(this));
            (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = _computeCurrentVirtualBalances(balancesScaled18);

            (minPrice, maxPrice) = ReClammMath.computePriceRange(balancesScaled18, virtualBalanceA, virtualBalanceB);
        } else {
            minPrice = _INITIAL_MIN_PRICE;
            maxPrice = _INITIAL_MAX_PRICE;
        }
    }

    /// @inheritdoc IReClammPoolExtension
    function computeCurrentPoolCenteredness() external view onlyPoolDelegateCall returns (uint256, bool) {
        (, , , uint256[] memory currentBalancesScaled18) = _VAULT.getPoolTokenInfo(address(this));
        return ReClammMath.computeCenteredness(currentBalancesScaled18, _lastVirtualBalanceA, _lastVirtualBalanceB);
    }

    /// @inheritdoc IReClammPoolExtension
    function computeCurrentVirtualBalances()
        external
        view
        onlyPoolDelegateCall
        returns (uint256 currentVirtualBalanceA, uint256 currentVirtualBalanceB, bool changed)
    {
        (, currentVirtualBalanceA, currentVirtualBalanceB, changed) = _getRealAndVirtualBalances();
    }

    /// @inheritdoc IReClammPoolExtension
    function computeCurrentSpotPrice() external view onlyPoolDelegateCall returns (uint256) {
        (
            uint256[] memory balancesScaled18,
            uint256 currentVirtualBalanceA,
            uint256 currentVirtualBalanceB,

        ) = _getRealAndVirtualBalances();

        return (balancesScaled18[b] + currentVirtualBalanceB).divDown(balancesScaled18[a] + currentVirtualBalanceA);
    }

    /// @inheritdoc IReClammPoolExtension
    function isPoolWithinTargetRangeUsingCurrentVirtualBalances()
        external
        view
        onlyPoolDelegateCall
        returns (bool isWithinTargetRange, bool virtualBalancesChanged)
    {
        (, , , uint256[] memory balancesScaled18) = _VAULT.getPoolTokenInfo(address(this));
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

    /*******************************************************************************
                                    Hook Functions
    *******************************************************************************/

    /// @notice Forwards onAfterInitialize to the secondary hook. (This hook is unused by the main pool contract.)
    function onAfterInitialize(
        uint256[] memory exactAmountsIn,
        uint256 bptAmountOut,
        bytes memory userData
    ) external onlyVault onlyWithHookContract returns (bool) {
        return IHooks(_HOOK_CONTRACT).onAfterInitialize(exactAmountsIn, bptAmountOut, userData);
    }

    /// @notice Forwards onAfterAddLiquidity to the secondary hook. (This hook is unused by the main pool contract.)
    function onAfterAddLiquidity(
        address router,
        address pool_,
        AddLiquidityKind kind,
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256 bptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory userData
    ) public onlyVault onlyWithHookContract returns (bool, uint256[] memory) {
        return
            IHooks(_HOOK_CONTRACT).onAfterAddLiquidity(
                router,
                pool_,
                kind,
                amountsInScaled18,
                amountsInRaw,
                bptAmountOut,
                balancesScaled18,
                userData
            );
    }

    /// @notice Forwards onAfterRemoveLiquidity to the secondary hook. (This hook is unused by the main pool contract.)
    function onAfterRemoveLiquidity(
        address router,
        address pool_,
        RemoveLiquidityKind kind,
        uint256 bptAmountIn,
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory balancesScaled18,
        bytes memory userData
    ) public onlyVault onlyWithHookContract returns (bool, uint256[] memory) {
        return
            IHooks(_HOOK_CONTRACT).onAfterRemoveLiquidity(
                router,
                pool_,
                kind,
                bptAmountIn,
                amountsOutScaled18,
                amountsOutRaw,
                balancesScaled18,
                userData
            );
    }

    /// @notice Forwards onBeforeSwap to the secondary hook. (This hook is unused by the main pool contract.)
    function onBeforeSwap(
        PoolSwapParams calldata params,
        address pool_
    ) public onlyVault onlyWithHookContract returns (bool) {
        return IHooks(_HOOK_CONTRACT).onBeforeSwap(params, pool_);
    }

    /// @notice Forwards onAfterSwap to the secondary hook. (This hook is unused by the main pool contract.)
    function onAfterSwap(
        AfterSwapParams calldata params
    ) public onlyVault onlyWithHookContract returns (bool, uint256) {
        return IHooks(_HOOK_CONTRACT).onAfterSwap(params);
    }

    /// @notice Forwards the call to the secondary hook. (This hook is unused by the main pool contract.)
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool_,
        uint256 staticSwapFeePercentage
    ) public view onlyWithHookContract returns (bool, uint256) {
        // This does not need onlyVault, as it's defined as a view function in the interface.
        return IHooks(_HOOK_CONTRACT).onComputeDynamicSwapFeePercentage(params, pool_, staticSwapFeePercentage);
    }

    /*******************************************************************************
                                   Internal Helpers
    *******************************************************************************/

    // This function is needed in the getters, and in the old code was coming from BalancerPoolToken.
    // That implementation just called the Vault, so we'll just do the same thing here.
    function _totalSupply() internal view returns (uint256) {
        // Since this is a delegate call, "this" is the pool address.
        return _VAULT.totalSupply(address(this));
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
        (, , , balancesScaled18) = _VAULT.getPoolTokenInfo(address(this));
        (currentVirtualBalanceA, currentVirtualBalanceB, changed) = _computeCurrentVirtualBalances(balancesScaled18);
    }

    function _getLastVirtualBalances() internal view returns (uint256[] memory) {
        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[a] = _lastVirtualBalanceA;
        lastVirtualBalances[b] = _lastVirtualBalanceB;

        return lastVirtualBalances;
    }

    /*******************************************************************************
                                   Modifier Helpers
    *******************************************************************************/

    function _ensureHookContract() internal view {
        if (_HOOK_CONTRACT == address(0)) {
            // Should not happen. Hook flags would not go beyond ReClamm-required ones without a contract.
            revert NotImplemented();
        }
    }

    function _ensurePoolDelegateCall() internal view {
        // If this is a delegate call from the Pool, the address of the contract should be the Pool's,
        // not the extension.
        if (address(this) != address(_POOL)) {
            revert NotPoolDelegateCall();
        }
    }

    /*******************************************************************************
                                    Proxy Functions
    *******************************************************************************/

    function pool() external view returns (IReClammPoolMain) {
        return _POOL;
    }

    // For ReClammCommon Vault access.
    function _getBalancerVault() internal view override returns (IVault) {
        return _VAULT;
    }

    /*******************************************************************************
                                     Default handlers
    *******************************************************************************/

    receive() external payable {
        revert IVaultErrors.CannotReceiveEth();
    }

    // solhint-disable no-complex-fallback

    fallback() external payable {
        if (msg.value > 0) {
            revert IVaultErrors.CannotReceiveEth();
        }

        revert NotImplemented();
    }
}
