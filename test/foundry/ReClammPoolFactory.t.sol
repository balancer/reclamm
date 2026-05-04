// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { ReClammPriceParams } from "../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { ReClammPoolHelper } from "../../contracts/ReClammPoolHelper.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { a, b } from "../../contracts/lib/ReClammMath.sol";

contract ReClammPoolFactoryTest is BaseReClammTest {
    using ArrayHelpers for *;
    using CastingHelpers for address[];

    string private constant _FACTORY_VERSION = "Factory v1";

    function testWrongHelperFactoryDeployment() public {
        // Deploy a helper bound to an arbitrary address that is not the factory's Vault.
        ReClammPoolHelper helperWithWrongVault = new ReClammPoolHelper(IVault(address(0xdeadbeef)));

        vm.expectRevert(ReClammPoolFactory.WrongHelperDeployment.selector);
        new ReClammPoolFactory(vault, helperWithWrongVault, 365 days, _FACTORY_VERSION, _POOL_VERSION);
    }

    function testDirectFactoryDeployment() public {
        ReClammPoolHelper helper = new ReClammPoolHelper(vault);
        ReClammPoolFactory newFactory = new ReClammPoolFactory(
            vault,
            helper,
            365 days,
            _FACTORY_VERSION,
            _POOL_VERSION
        );

        assertEq(address(newFactory.reClammPoolHelper()), address(helper), "Wrong helper stored on factory");
        assertEq(address(newFactory.getVault()), address(vault), "Factory bound to wrong Vault");
    }

    function testGetPoolVersion() public {
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);
        assertEq(poolFactory.getPoolVersion(), _POOL_VERSION, "Wrong pool version");
    }

    function testFactoryVersion() public {
        ReClammPoolHelper helper = new ReClammPoolHelper(vault);
        ReClammPoolFactory poolFactory = new ReClammPoolFactory(
            vault,
            helper,
            365 days,
            _FACTORY_VERSION,
            _POOL_VERSION
        );
        assertEq(poolFactory.version(), _FACTORY_VERSION, "Wrong factory version");
    }

    function testIsPoolFromFactory() public {
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);
        address newPool = _createPoolWithRealFactory(poolFactory);

        assertTrue(poolFactory.isPoolFromFactory(newPool), "Pool should be tracked by its factory");
        assertFalse(poolFactory.isPoolFromFactory(pool), "Pool from a different factory should not be tracked");
    }

    function testPoolRegistrationConfig() public {
        ReClammPoolFactory poolFactory = deployReClammPoolFactoryWithDefaultParams(vault);
        address newPool = _createPoolWithRealFactory(poolFactory);

        PoolConfig memory poolConfig = vault.getPoolConfig(newPool);
        assertTrue(
            poolConfig.liquidityManagement.disableUnbalancedLiquidity,
            "Unbalanced liquidity should be disabled"
        );
        assertFalse(poolConfig.liquidityManagement.enableDonation, "Donation should be disabled");
        assertFalse(poolConfig.liquidityManagement.enableAddLiquidityCustom, "Custom add liquidity should be disabled");
        assertFalse(
            poolConfig.liquidityManagement.enableRemoveLiquidityCustom,
            "Custom remove liquidity should be disabled"
        );

        HooksConfig memory hooksConfig = vault.getHooksConfig(newPool);
        assertEq(hooksConfig.hooksContract, newPool, "Pool should be its own hook contract");
    }

    function _createPoolWithRealFactory(ReClammPoolFactory poolFactory) private returns (address newPool) {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc), address(dai)].toMemoryArray().asIERC20()
        );

        PoolRoleAccounts memory roleAccounts = PoolRoleAccounts({
            pauseManager: address(0),
            swapFeeManager: admin,
            poolCreator: alice
        });

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _DEFAULT_MIN_PRICE,
            initialMaxPrice: _DEFAULT_MAX_PRICE,
            initialTargetPrice: _DEFAULT_TARGET_PRICE,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens, rateProviders);

        newPool = poolFactory.create(
            "ReClamm Pool",
            "RECLAMM_POOL",
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
    }
}
