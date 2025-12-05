// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IReClammPoolExtension } from "./IReClammPoolExtension.sol";
import { IReClammPoolMain } from "./IReClammPoolMain.sol";

/**
 * @notice Struct with data for deploying a new ReClammPool.
 * @param name The name of the pool
 * @param symbol The symbol of the pool
 * @param version The pool version (distinct from the factory version)
 * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
 * @param centerednessMargin How far the price can be from the center before the price range starts to move
 * @param initialMinPrice The initial minimum price of token A in terms of token B as an 18-decimal FP value
 * @param initialMaxPrice The initial maximum price of token A in terms of token B as an 18-decimal FP value
 * @param initialTargetPrice The initial target price of token A in terms of token B as an 18-decimal FP value
 * @param tokenAPriceIncludesRate Whether the amount of token A is scaled by the rate when calculating the price
 * @param tokenBPriceIncludesRate Whether the amount of token B is scaled by the rate when calculating the price
 */
struct ReClammPoolParams {
    string name;
    string symbol;
    string version;
    uint256 dailyPriceShiftExponent;
    uint64 centerednessMargin;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

/**
 * @notice ReClammPool initialization parameters.
 * @dev ReClamm pools may contain wrapped tokens (with rate providers), in which case there are two options for
 * providing the initialization prices (and the initialization balances can be calculated in terms of either
 * token). If the price is that of the wrapped token, we should not apply the rate, so the flag for that token
 * should be false. If the price is given in terms of the underlying, we do need to apply the rate when computing
 * the initialization balances.
 *
 * @param initialMinPrice The initial minimum price of token A in terms of token B as an 18-decimal FP value
 * @param initialMaxPrice The initial maximum price of token A in terms of token B as an 18-decimal FP value
 * @param initialTargetPrice The initial target price of token A in terms of token B as an 18-decimal FP value
 * @param tokenAPriceIncludesRate Whether the amount of token A is scaled by the rate when calculating the price
 * @param tokenBPriceIncludesRate Whether the amount of token B is scaled by the rate when calculating the price
 */
struct ReClammPriceParams {
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    bool tokenAPriceIncludesRate;
    bool tokenBPriceIncludesRate;
}

/// @notice Full interface for the ReClammPool, encompassing main and extension functions.
// wake-disable-next-line unused-contract
interface IReClammPool is IReClammPoolMain, IReClammPoolExtension {
    // solhint-disable-previous-line no-empty-blocks
}
