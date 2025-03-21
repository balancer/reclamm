// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { BaseContractsDeployer } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseContractsDeployer.sol";

import { ReClammPoolFactory } from "../../../contracts/ReClammPoolFactory.sol";
import { ReClammPoolFactoryMock } from "../../../contracts/test/ReClammPoolFactoryMock.sol";
/**
 * @dev This contract contains functions for deploying mocks and contracts related to the "Acl Amm Pool". These
 * functions should have support for reusing artifacts from the hardhat compilation.
 */
contract ReClammPoolContractsDeployer is BaseContractsDeployer {
    string private artifactsRootDir = "artifacts/";

    constructor() {
        // if this external artifact path exists, it means we are running outside of this repo
        if (vm.exists("artifacts/@balancer-labs/v3-pool-reClamm/")) {
            artifactsRootDir = "artifacts/@balancer-labs/v3-pool-reClamm/";
        }
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
