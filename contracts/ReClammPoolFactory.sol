// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

// solhint-disable-next-line no-unused-import
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    PoolRoleAccounts,
    LiquidityManagement
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import { ReClammPool } from "./ReClammPool.sol";
import { ReClammPoolParams } from "./interfaces/IReClammPool.sol";

/// @notice ReClammPool factory.
contract ReClammPoolFactory is IPoolVersion, BasePoolFactory, Version {
    string private _poolVersion;

    /**
     * @param initialMinPrice The initial minimum price of the pool
     * @param initialMaxPrice The initial maximum price of the pool
     * @param initialTargetPrice The initial target price of the pool
     * @param priceTokenAWithRate Whether the amount of token A is scaled by the rate in the price value
     * @param priceTokenBWithRate Whether the amount of token B is scaled by the rate in the price value
     */
    struct ReClammPriceParams {
        uint256 initialMinPrice;
        uint256 initialMaxPrice;
        uint256 initialTargetPrice;
        bool priceTokenAWithRate;
        bool priceTokenBWithRate;
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
     * @param priceParams Initial min, max and target prices, as well as a flag to indicate if the price is scaled by
     * the rate
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
        uint64 centerednessMargin,
        bytes32 salt
    ) external returns (address pool) {
        if (roleAccounts.poolCreator != address(0)) {
            revert StandardPoolWithCreator();
        }

        // The ReClammPool only supports 2 tokens.
        if (tokens.length > 2) {
            revert IVaultErrors.MaxTokens();
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
                    priceTokenAWithRate: priceParams.priceTokenAWithRate,
                    priceTokenBWithRate: priceParams.priceTokenBWithRate,
                    dailyPriceShiftExponent: dailyPriceShiftExponent,
                    centerednessMargin: centerednessMargin
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
