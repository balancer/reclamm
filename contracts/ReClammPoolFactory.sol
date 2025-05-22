// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// solhint-disable-next-line no-unused-import
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    TokenType,
    PoolRoleAccounts,
    LiquidityManagement
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import { ReClammPool } from "./ReClammPool.sol";
import { ReClammPoolParams } from "./interfaces/IReClammPool.sol";

/// @notice ReClammPool factory.
contract ReClammPoolFactory is IPoolVersion, BasePoolFactory, Version {
    using SafeCast for uint256;

    string private _poolVersion;

    /**
     * @notice ReClammPool initialization parameters.
     * @dev ReClamm pools may contain wrapped tokens (with rate providers), in which case there are two options for
     * providing the initialization prices (and the initialization balances can be calculated in terms of either
     * token). If the price is that of the wrapped token, we should not apply the rate, so the flag for that token
     * should be false. If the price is given in terms of the underlying, we do need to apply the rate when computing
     * the initialization balances.
     *
     * @param initialMinPrice The initial minimum price of token A in terms of token B
     * @param initialMaxPrice The initial maximum price of token A in terms of token B
     * @param initialTargetPrice The initial target price of token A in terms of token B
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

    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(ReClammPool).creationCode) Version(factoryVersion) {
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /**
     * @notice Deploys a new `ReClammPool`.
     * @param name The name of the pool
     * @param symbol The symbol of the pool
     * @param tokens An array of descriptors for the tokens the pool will manage
     * @param roleAccounts Addresses the Vault will allow to change certain pool settings
     * @param swapFeePercentage Initial swap fee percentage
     * @param priceParams Initial min, max and target prices; flags indicating whether token prices incorporate rates
     * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
     * @param centerednessMargin How far the price can be from the center before the price range starts to move
     * @param salt The salt value that will be passed to deployment
     */
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        PoolRoleAccounts memory roleAccounts,
        uint256 swapFeePercentage,
        ReClammPriceParams memory priceParams,
        uint256 dailyPriceShiftExponent,
        uint256 centerednessMargin,
        bytes32 salt
    ) external returns (address pool) {
        if (roleAccounts.poolCreator != address(0)) {
            revert StandardPoolWithCreator();
        }

        // The ReClammPool only supports 2 tokens.
        if (tokens.length > 2) {
            revert IVaultErrors.MaxTokens();
        }

        if (priceParams.tokenAPriceIncludesRate && tokens[0].tokenType != TokenType.WITH_RATE) {
            revert IVaultErrors.InvalidTokenType();
        }
        if (priceParams.tokenBPriceIncludesRate && tokens[1].tokenType != TokenType.WITH_RATE) {
            revert IVaultErrors.InvalidTokenType();
        }

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = false;
        liquidityManagement.disableUnbalancedLiquidity = true;

        pool = _create(
            abi.encode(
                ReClammPoolParams({
                    name: name,
                    symbol: symbol,
                    version: _poolVersion,
                    initialMinPrice: priceParams.initialMinPrice,
                    initialMaxPrice: priceParams.initialMaxPrice,
                    initialTargetPrice: priceParams.initialTargetPrice,
                    tokenAPriceIncludesRate: priceParams.tokenAPriceIncludesRate,
                    tokenBPriceIncludesRate: priceParams.tokenBPriceIncludesRate,
                    dailyPriceShiftExponent: dailyPriceShiftExponent,
                    centerednessMargin: centerednessMargin.toUint64()
                }),
                getVault()
            ),
            salt
        );

        _registerPoolWithVault(
            pool,
            tokens,
            swapFeePercentage,
            false, // not exempt from protocol fees
            roleAccounts,
            pool, // The pool is the hook
            liquidityManagement
        );
    }
}
