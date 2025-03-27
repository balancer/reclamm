// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import { PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { BaseContractsDeployer } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseContractsDeployer.sol";
import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";

import { ReClammPoolFactory } from "../../../contracts/ReClammPoolFactory.sol";
import { ReClammPoolFactoryMock } from "../../../contracts/test/ReClammPoolFactoryMock.sol";
import { ReClammPoolParams } from "../../../contracts/interfaces/IReClammPool.sol";
/**
 * @dev This contract contains functions for deploying mocks and contracts related to the "ReClamm Pool". These
 * functions should have support for reusing artifacts from the hardhat compilation.
 */
contract ReClammPoolContractsDeployer is BaseContractsDeployer {
    using CastingHelpers for address[];

    struct DefaultDeployParams {
        string name;
        string symbol;
        uint256 defaultPriceShiftDailyRate;
        uint256 defaultCenterednessMargin;
        uint96 defaultFourthRootPriceRatio;
        string poolVersion;
        string factoryVersion;
    }

    string private artifactsRootDir = "artifacts/";
    DefaultDeployParams private defaultParams;

    uint256 private _saltIndex = 0;

    constructor() {
        defaultParams = DefaultDeployParams({
            name: "ReClamm Pool",
            symbol: "RECLAMMPOOL",
            defaultPriceShiftDailyRate: 100e16, // 100%
            defaultCenterednessMargin: 10e16, // 10%
            defaultFourthRootPriceRatio: 1.41421356e18, // Price Range of 4 (fourth square root is 1.41)
            poolVersion: "ReClamm Pool v1",
            factoryVersion: "ReClamm Pool Factory v1"
        });

        // if this external artifact path exists, it means we are running outside of this repo
        if (vm.exists("artifacts/@balancer-labs/v3-pool-reClamm/")) {
            artifactsRootDir = "artifacts/@balancer-labs/v3-pool-reClamm/";
        }
    }

    function createReClammPool(
        address[] memory tokens,
        string memory label,
        IVaultMock vault,
        address poolCreator
    ) internal returns (address newPool, bytes memory poolArgs) {
        string memory poolVersion = "ReClamm Pool v1";
        string memory factoryVersion = "ReClamm Pool Factory v1";

        ReClammPoolFactory poolFactory = deployReClammPoolFactory(vault, 1 days, factoryVersion, poolVersion);
        PoolRoleAccounts memory roleAccounts;

        IERC20[] memory _tokens = tokens.asIERC20();

        newPool = ReClammPoolFactory(poolFactory).create(
            defaultParams.name,
            defaultParams.symbol,
            vault.buildTokenConfig(_tokens),
            roleAccounts,
            0,
            defaultParams.defaultPriceShiftDailyRate,
            defaultParams.defaultFourthRootPriceRatio,
            SafeCast.toUint64(defaultParams.defaultCenterednessMargin),
            bytes32(_saltIndex++)
        );
        vm.label(newPool, label);

        // poolArgs is used to check pool deployment address with create2.
        poolArgs = abi.encode(
            ReClammPoolParams({
                name: defaultParams.name,
                symbol: defaultParams.symbol,
                version: defaultParams.poolVersion,
                priceShiftDailyRate: defaultParams.defaultPriceShiftDailyRate,
                fourthRootPriceRatio: defaultParams.defaultFourthRootPriceRatio,
                centerednessMargin: SafeCast.toUint64(defaultParams.defaultCenterednessMargin)
            }),
            vault
        );

        // Cannot set the pool creator directly on a standard Balancer stable pool factory.
        vault.manualSetPoolCreator(newPool, poolCreator);
    }

    function deployReClammPoolFactoryWithDefaultParams(IVault vault) internal returns (ReClammPoolFactory) {
        return deployReClammPoolFactory(vault, 1 days, defaultParams.factoryVersion, defaultParams.poolVersion);
    }

    function deployReClammPoolFactory(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) internal returns (ReClammPoolFactory) {
        if (reusingArtifacts) {
            return
                ReClammPoolFactory(
                    deployCode(
                        _computeReClammPath(type(ReClammPoolFactory).name),
                        abi.encode(vault, pauseWindowDuration, factoryVersion, poolVersion)
                    )
                );
        } else {
            return new ReClammPoolFactory(vault, pauseWindowDuration, factoryVersion, poolVersion);
        }
    }

    function deployReClammPoolFactoryMock(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) internal returns (ReClammPoolFactoryMock) {
        if (reusingArtifacts) {
            return
                ReClammPoolFactoryMock(
                    deployCode(
                        _computeReClammTestPath(type(ReClammPoolFactoryMock).name),
                        abi.encode(vault, pauseWindowDuration, factoryVersion, poolVersion)
                    )
                );
        } else {
            return new ReClammPoolFactoryMock(vault, pauseWindowDuration, factoryVersion, poolVersion);
        }
    }

    function _computeReClammPath(string memory name) private view returns (string memory) {
        return string(abi.encodePacked(artifactsRootDir, "contracts/", name, ".sol/", name, ".json"));
    }

    function _computeReClammTestPath(string memory name) private view returns (string memory) {
        return string(abi.encodePacked(artifactsRootDir, "contracts/test/", name, ".sol/", name, ".json"));
    }
}
