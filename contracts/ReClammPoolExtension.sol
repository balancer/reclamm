// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { PoolConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath, a, b } from "./lib/ReClammMath.sol";
import { PriceRatioState } from "./lib/ReClammMath.sol";
import { ReClammCommon } from "./ReClammCommon.sol";
import { ReClammPoolParams } from "./interfaces/IReClammPoolMain.sol";
import "./interfaces/IReClammPoolExtension.sol";

contract ReClammPoolExtension is IReClammPoolExtension, ReClammCommon {
    using ReClammMath for *;

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

    constructor(IReClammPoolMain reclammPool, IVault vault, ReClammPoolParams memory params, address hookContract) {
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

        // Consider defining this value as a constant so that we don't need to call this function twice.
        _MAX_DAILY_PRICE_RATIO_UPDATE_RATE = FixedPoint.powUp(2e18, _MAX_DAILY_PRICE_SHIFT_EXPONENT);

        _HOOK_CONTRACT = hookContract;
    }

    /*******************************************************************************
                                    Pool State Getters
    *******************************************************************************/

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

    // This function is needed in the getters, and in the old code was coming from BalancerPoolToken.
    // That implementation just called the Vault, so we'll just do the same thing here.
    function _totalSupply() internal view returns (uint256) {
        // Since this is a delegate call, "this" is the pool address.
        return _VAULT.totalSupply(address(this));
    }

    function _getLastVirtualBalances() internal view returns (uint256[] memory) {
        uint256[] memory lastVirtualBalances = new uint256[](2);
        lastVirtualBalances[a] = _lastVirtualBalanceA;
        lastVirtualBalances[b] = _lastVirtualBalanceB;

        return lastVirtualBalances;
    }

    // For ReClammCommon Vault access.
    function _getBalancerVault() internal view override returns (IVault) {
        return _VAULT;
    }

    /*******************************************************************************
                                    Proxy Functions
    *******************************************************************************/

    function pool() external view returns (IReClammPoolMain) {
        return _POOL;
    }

    function _ensurePoolDelegateCall() internal view {
        // If this is a delegate call from the Pool, the address of the contract should be the Pool's,
        // not the extension.
        if (address(this) != address(_POOL)) {
            revert NotPoolDelegateCall();
        }
    }
}
