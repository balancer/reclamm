// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { PriceRatioState } from "./lib/ReClammMath.sol";

/**
 * @notice Storage layout for the ReClammPool.
 * @dev This contract has no code, but is inherited by both ReClamm contracts (main and extension). In order to ensure
 * that *only* the Pool contract's storage is actually used, calls to the extension contract must be delegate calls
 * made through the main Pool.
 */
abstract contract ReClammStorage {
    /*******************************************************************************
                                       Constants
    *******************************************************************************/

    // Fees are 18-decimal, floating point values, which will be stored in the Vault using 24 bits.
    // This means they have 0.00001% resolution (i.e., any non-zero bits < 1e11 will cause precision loss).
    // Minimum values help make the math well-behaved (i.e., the swap fee should overwhelm any rounding error).
    // Maximum values protect users by preventing permissioned actors from setting excessively high swap fees.
    uint256 internal constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // The maximum pool centeredness allowed to consider the pool within the target range.
    uint256 internal constant _MAX_CENTEREDNESS_MARGIN = 90e16; // 90%

    // The daily price shift exponent is a percentage that defines the speed at which the virtual balances will change
    // over the course of one day. A value of 100% (i.e, FP 1) means that the min and max prices will double (or halve)
    // every day, until the pool price is within the range defined by the margin. This constant defines the maximum
    // "price shift" velocity.
    uint256 internal constant _MAX_DAILY_PRICE_SHIFT_EXPONENT = 100e16; // 100%

    // The maximum daily price ratio change rate is given by 2^_MAX_DAILY_PRICE_SHIFT_EXPONENT.
    // This is somewhat arbitrary, but it makes sense to link these rates; i.e., we are setting the maximum speed
    // of expansion or contraction to equal the maximum speed of the price shift. It is expressed as a multiple;
    // i.e., 8e18 means it can change by 8x per day.
    uint256 internal constant _MAX_DAILY_PRICE_RATIO_UPDATE_RATE = 2e18;

    // Price ratio updates must have both a minimum duration and a maximum daily rate. For instance, an update rate of
    // FP 2 means the ratio one day later must be at least half and at most double the rate at the start of the update.
    uint256 internal constant _MIN_PRICE_RATIO_UPDATE_DURATION = 1 days;

    // There is also a minimum delta, to keep the math well-behaved.
    uint256 internal constant _MIN_PRICE_RATIO_DELTA = 1e6;

    uint256 internal constant _MAX_TOKEN_DECIMALS = 18;
    // This represents the maximum deviation from the ideal state (i.e., at target price and near centered) after
    // initialization, to prevent arbitration losses.
    uint256 internal constant _BALANCE_RATIO_AND_PRICE_TOLERANCE = 0.01e16; // 0.01%

    /*******************************************************************************
                                       Immutables
    *******************************************************************************/

    // These immutables are only used during initialization, to set the virtual balances and price ratio in a more
    // user-friendly manner.
    uint256 internal immutable _INITIAL_MIN_PRICE;
    uint256 internal immutable _INITIAL_MAX_PRICE;
    uint256 internal immutable _INITIAL_TARGET_PRICE;
    uint256 internal immutable _INITIAL_DAILY_PRICE_SHIFT_EXPONENT;
    uint256 internal immutable _INITIAL_CENTEREDNESS_MARGIN;

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
    bool internal immutable _TOKEN_A_PRICE_INCLUDES_RATE;
    bool internal immutable _TOKEN_B_PRICE_INCLUDES_RATE;

    // ReClamm pools are always their own hook from the Vault's perspective, but also allow forwarding to an optional
    // second hook contract.
    address internal immutable _HOOK_CONTRACT;

    /*******************************************************************************
                                    State Variables
    *******************************************************************************/

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
}
