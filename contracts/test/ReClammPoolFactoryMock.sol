// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { CREATE3 } from "@balancer-labs/v3-solidity-utils/contracts/solmate/CREATE3.sol";

import { ReClammPoolParams, ReClammPriceParams } from "../interfaces/IReClammPool.sol";
import { IReClammPoolMain } from "../interfaces/IReClammPoolMain.sol";
import { ReClammPoolExtension } from "../ReClammPoolExtension.sol";
import { ReClammPoolLib } from "../lib/ReClammPoolLib.sol";
import { ReClammPoolMock } from "./ReClammPoolMock.sol";

/// @notice ReClammPool Mock factory. It is identical to the real factory, except for deploying a mock pool.
contract ReClammPoolFactoryMock is IPoolVersion, BasePoolFactory, Version {
    using SafeCast for uint256;

    string private _poolVersion;

    /// @notice The actual deployed address of the pool doesn't match the predicted value.
    error PoolAddressMismatch();

    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(ReClammPoolMock).creationCode) Version(factoryVersion) {
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /**
     * @notice Gets deployment address for a given salt (CREATE3 - doesn't depend on constructor args).
     * @dev Note that the BasePoolFactory's `getDeploymentAddress` will not work here, since we're using create3.
     */
    function getDeploymentAddress(bytes32 salt) public view returns (address) {
        return CREATE3.getDeployed(_computeFinalSalt(salt));
    }

    /**
     * @notice Deploys a new `ReClammPoolMock`.
     * @param name The name of the pool
     * @param symbol The symbol of the pool
     * @param tokens An array of descriptors for the tokens the pool will manage
     * @param roleAccounts Addresses the Vault will allow to change certain pool settings
     * @param swapFeePercentage Initial swap fee percentage
     * @param hookContract ReClamm pools are their own hooks, but can forward to an optional second hook
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
        address hookContract,
        ReClammPriceParams memory priceParams,
        uint256 dailyPriceShiftExponent,
        uint256 centerednessMargin,
        bytes32 salt
    ) external returns (address pool) {
        ReClammPoolLib.validateTokenAndPriceConfig(tokens, priceParams);

        bytes32 finalSalt = _computeFinalSalt(salt);

        // Predict pool address (CREATE3 only depends on salt).
        pool = CREATE3.getDeployed(finalSalt);

        {
            ReClammPoolParams memory params = ReClammPoolParams({
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
            });

            // Deploy pool extension with predicted pool address (regular create; we don't care about the address).
            ReClammPoolExtension extensionContract = new ReClammPoolExtension(
                IReClammPoolMain(pool),
                getVault(),
                params,
                hookContract
            );

            // Deploy main pool with CREATE3.
            address deployed = CREATE3.deploy(
                finalSalt,
                abi.encodePacked(
                    type(ReClammPoolMock).creationCode,
                    abi.encode(params, getVault(), extensionContract, hookContract)
                ),
                0
            );

            // Ensure the deployment address matches the predicted value.
            if (deployed != pool) {
                revert PoolAddressMismatch();
            }
        }

        // Register the pool. Would normally be done by the base contract `_create`, but we can't call that, as it
        // doesn't do what we want.
        _registerPoolWithFactory(pool);

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = false;
        liquidityManagement.disableUnbalancedLiquidity = true;

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
