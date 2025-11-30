// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IReClammPool } from "./IReClammPool.sol";

/**
 * @notice ReClamm Pool data that cannot change after deployment.
 * @dev Note that the initial prices are used only during pool initialization. After the initialization, the prices
 * will shift according to price ratio and pool centeredness.
 *
 * @param tokens Pool tokens, sorted in token registration order
 * @param decimalScalingFactors Adjust for token decimals to retain calculation precision. FP(1) for 18-decimal tokens
 * @param tokenAPriceIncludesRate True if the prices incorporate a rate for token A
 * @param tokenBPriceIncludesRate True if the prices incorporate a rate for token B
 * @param minSwapFeePercentage The minimum allowed static swap fee percentage; mitigates precision loss due to rounding
 * @param maxSwapFeePercentage The maximum allowed static swap fee percentage
 * @param initialMinPrice The initial minimum price of token A in terms of token B (possibly applying rates)
 * @param initialMaxPrice The initial maximum price of token A in terms of token B (possibly applying rates)
 * @param initialTargetPrice The initial target price of token A in terms of token B (possibly applying rates)
 * @param initialDailyPriceShiftExponent The initial daily price shift exponent
 * @param initialCenterednessMargin The initial centeredness margin (threshold for initiating a range update)
 * @param hookContract ReClamm pools are always their own hook, but also allow forwarding to an optional hook contract
 * @param maxCenterednessMargin The maximum centeredness margin for the pool, as an 18-decimal FP percentage
 * @param maxDailyPriceShiftExponent The maximum exponent for the pool's price shift, as an 18-decimal FP percentage
 * @param maxDailyPriceRatioUpdateRate The maximum percentage the price range can expand/contract per day
 * @param minPriceRatioUpdateDuration The minimum duration for the price ratio update, expressed in seconds
 * @param minPriceRatioDelta The minimum absolute difference between current and new fourth root price ratio
 * @param balanceRatioAndPriceTolerance The maximum amount initialized pool parameters can deviate from ideal values
 */
struct ReClammPoolImmutableData {
    // Base Pool
    IERC20[] tokens;
    uint256[] decimalScalingFactors;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
    uint256 minSwapFeePercentage;
    uint256 maxSwapFeePercentage;
    // Initialization
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    uint256 initialDailyPriceShiftExponent;
    uint256 initialCenterednessMargin;
    address hookContract;
    // Operating Limits
    uint256 maxCenterednessMargin;
    uint256 maxDailyPriceShiftExponent;
    uint256 maxDailyPriceRatioUpdateRate;
    uint256 minPriceRatioUpdateDuration;
    uint256 minPriceRatioDelta;
    uint256 balanceRatioAndPriceTolerance;
}

/**
 * @notice Snapshot of current ReClamm Pool data that can change.
 * @dev Note that live balances will not necessarily be accurate if the pool is in Recovery Mode. Withdrawals
 * in Recovery Mode do not make external calls (including those necessary for updating live balances), so if
 * there are withdrawals, raw and live balances will be out of sync until Recovery Mode is disabled.
 *
 * Base Pool:
 * @param balancesLiveScaled18 Token balances after paying yield fees, applying decimal scaling and rates
 * @param tokenRates 18-decimal FP values for rate tokens (e.g., yield-bearing), or FP(1) for standard tokens
 * @param staticSwapFeePercentage 18-decimal FP value of the static swap fee percentage
 * @param totalSupply The current total supply of the pool tokens (BPT)
 *
 * ReClamm:
 * @param lastTimestamp The timestamp of the last user interaction
 * @param lastVirtualBalances The last virtual balances of the pool
 * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
 * @param dailyPriceShiftBase Internal time constant used to update virtual balances (1 - tau)
 * @param centerednessMargin The centeredness margin of the pool
 * @param currentPriceRatio The current price ratio, an interpolation of the price ratio state
 * @param currentFourthRootPriceRatio The current fourth root price ratio (stored in the price ratio state)
 * @param startFourthRootPriceRatio The fourth root price ratio at the start of an update
 * @param endFourthRootPriceRatio The fourth root price ratio at the end of an update
 * @param priceRatioUpdateStartTime The timestamp when the update begins
 * @param priceRatioUpdateEndTime The timestamp when the update ends
 *
 * Pool State:
 * @param isPoolInitialized If false, the pool has not been seeded with initial liquidity, so operations will revert
 * @param isPoolPaused If true, the pool is paused, and all non-recovery-mode state-changing operations will revert
 * @param isPoolInRecoveryMode If true, Recovery Mode withdrawals are enabled, and live balances may be inaccurate
 */
struct ReClammPoolDynamicData {
    // Base Pool
    uint256[] balancesLiveScaled18;
    uint256[] tokenRates;
    uint256 staticSwapFeePercentage;
    uint256 totalSupply;
    // ReClamm
    uint256 lastTimestamp;
    uint256[] lastVirtualBalances;
    uint256 dailyPriceShiftExponent;
    uint256 dailyPriceShiftBase;
    uint256 centerednessMargin;
    uint256 currentPriceRatio;
    uint256 currentFourthRootPriceRatio;
    uint256 startFourthRootPriceRatio;
    uint256 endFourthRootPriceRatio;
    uint32 priceRatioUpdateStartTime;
    uint32 priceRatioUpdateEndTime;
    // Pool State
    bool isPoolInitialized;
    bool isPoolPaused;
    bool isPoolInRecoveryMode;
}

interface IReClammPoolExtension {
    /*******************************************************************************
                              Constants and immutables
    *******************************************************************************/

    /**
     * @notice Returns the ReClammPool address.
     * @dev The ReClammPool contains the most common, critical path pool operations.
     * @return reclammPool The address of the ReClammPool
     */
    function pool() external view returns (IReClammPool reclammPool);

    /*******************************************************************************
                                    Pool State Getters
    *******************************************************************************/

    /**
     * @notice Get dynamic pool data relevant to swap/add/remove calculations.
     * @return data A struct containing all dynamic ReClamm pool parameters
     */
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data);

    /**
     * @notice Get immutable pool data relevant to swap/add/remove calculations.
     * @return data A struct containing all immutable ReClamm pool parameters
     */
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data);
}
