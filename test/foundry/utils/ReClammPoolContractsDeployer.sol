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

import { ReClammMath, a, b } from "../../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactory } from "../../../contracts/ReClammPoolFactory.sol";
import { ReClammPriceParams } from "../../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolFactoryMock } from "../../../contracts/test/ReClammPoolFactoryMock.sol";
import { ReClammPoolParams } from "../../../contracts/interfaces/IReClammPool.sol";
/**
 * @dev This contract contains functions for deploying mocks and contracts related to the "ReClamm Pool". These
 * functions should have support for reusing artifacts from the hardhat compilation.
 */
contract ReClammPoolContractsDeployer is BaseContractsDeployer {
    using CastingHelpers for address[];
    using SafeCast for uint256;

    struct DefaultDeployParams {
        string name;
        string symbol;
        uint256 defaultMinPrice;
        uint256 defaultMaxPrice;
        uint256 defaultTargetPrice;
        bool defaultTokenAPriceIncludesRate;
        bool defaultTokenBPriceIncludesRate;
        uint256 defaultDailyPriceShiftExponent;
        uint256 defaultCenterednessMargin;
        string poolVersion;
        string factoryVersion;
    }

    string private artifactsRootDir = "artifacts/";
    DefaultDeployParams private defaultParams;

    uint256 private _saltIndex = 0;

    constructor() {
        // This is used only by E2E tests. They require a pool with the same initial balance in both tokens, so this
        // setup covers it.
        defaultParams = DefaultDeployParams({
            name: "ReClamm Pool",
            symbol: "RECLAMM_POOL",
            defaultMinPrice: 0.5e18,
            defaultMaxPrice: 2e18,
            defaultTargetPrice: 1e18,
            defaultTokenAPriceIncludesRate: false,
            defaultTokenBPriceIncludesRate: false,
            defaultDailyPriceShiftExponent: 100e16, // 100%
            defaultCenterednessMargin: 10e16, // 10%
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
        IRateProvider[] memory rateProviders = new IRateProvider[](0);
        return createReClammPool(tokens, rateProviders, label, vault, poolCreator);
    }

    function createReClammPool(
        address[] memory tokens,
        IRateProvider[] memory rateProviders,
        string memory label,
        IVaultMock vault,
        address poolCreator
    ) internal returns (address newPool, bytes memory poolArgs) {
        ReClammPoolFactoryMock poolFactory;
        {
            string memory poolVersion = "ReClamm Pool v1";
            string memory factoryVersion = "ReClamm Pool Factory v1";

            poolFactory = deployReClammPoolFactoryMock(vault, 1 days, factoryVersion, poolVersion);
        }

        PoolRoleAccounts memory roleAccounts;

        IERC20[] memory _tokens = tokens.asIERC20();
        IRateProvider[] memory _rateProviders = rateProviders;
        IVaultMock _vault = vault;
        string memory _label = label;

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: defaultParams.defaultMinPrice,
            initialMaxPrice: defaultParams.defaultMaxPrice,
            initialTargetPrice: defaultParams.defaultTargetPrice,
            tokenAPriceIncludesRate: defaultParams.defaultTokenAPriceIncludesRate,
            tokenBPriceIncludesRate: defaultParams.defaultTokenBPriceIncludesRate
        });

        newPool = ReClammPoolFactory(address(poolFactory)).create(
            defaultParams.name,
            defaultParams.symbol,
            _rateProviders.length == 0
                ? _vault.buildTokenConfig(_tokens)
                : _vault.buildTokenConfig(_tokens, _rateProviders),
            roleAccounts,
            0.001e16, // minimum swap fee
            priceParams,
            defaultParams.defaultDailyPriceShiftExponent,
            defaultParams.defaultCenterednessMargin.toUint64(),
            bytes32(_saltIndex++)
        );
        vm.label(newPool, _label);

        // Force the swap fee percentage, even if it's outside the allowed limits.
        // Tests are expected to set the fee percentage for specific purposes.
        vault.manualUnsafeSetStaticSwapFeePercentage(newPool, 0);

        address _poolCreator = poolCreator;

        // poolArgs is used to check pool deployment address with create2.
        poolArgs = abi.encode(
            ReClammPoolParams({
                name: defaultParams.name,
                symbol: defaultParams.symbol,
                version: defaultParams.poolVersion,
                initialMinPrice: priceParams.initialMinPrice,
                initialMaxPrice: priceParams.initialMaxPrice,
                initialTargetPrice: priceParams.initialTargetPrice,
                tokenAPriceIncludesRate: priceParams.tokenAPriceIncludesRate,
                tokenBPriceIncludesRate: priceParams.tokenBPriceIncludesRate,
                dailyPriceShiftExponent: defaultParams.defaultDailyPriceShiftExponent,
                centerednessMargin: defaultParams.defaultCenterednessMargin.toUint64()
            }),
            _vault
        );

        // Cannot set the pool creator directly on a standard Balancer stable pool factory.
        _vault.manualSetPoolCreator(newPool, _poolCreator);
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
