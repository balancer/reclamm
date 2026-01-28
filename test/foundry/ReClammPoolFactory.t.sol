// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TokenConfig, PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { CommonAuthentication } from "@balancer-labs/v3-vault/contracts/CommonAuthentication.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { ReClammPriceParams } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammPoolFactoryTest is BaseReClammTest {
    using CastingHelpers for *;
    using ArrayHelpers for *;

    ReClammPriceParams internal priceParams;
    IERC20[] internal sortedTokens;

    string internal name = "Factory Test Name";
    string internal symbol = "FTS";

    ReClammPoolFactory realFactory;

    function setUp() public virtual override {
        super.setUp();

        priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        address[] memory tokens = [address(usdc), address(dai)].toMemoryArray();
        sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());
    }

    function createPoolFactory() internal override returns (address) {
        realFactory = deployReClammPoolFactory(vault, 365 days, "Factory v1", _POOL_VERSION);
        vm.label(address(factory), "Acl Amm (Real) Factory");

        return address(realFactory);
    }

    function testVaultNotSet() public {
        vm.expectRevert(CommonAuthentication.VaultNotSet.selector);
        new ReClammPoolFactory(IVault(address(0)), 365 days, "f1", "v1");
    }

    function testPoolVersion() public view {
        assertEq(realFactory.getPoolVersion(), _POOL_VERSION, "Wrong pool version");
    }

    function testDeploymentAddress() public view {
        address predictedAddress = realFactory.getDeploymentAddress(ONE_BYTES32);
        assertEq(predictedAddress, 0xdb01fA030a59106f57FB67B372dF7AA3C1e86D2D, "Wrong address");
    }

    function testStandardPoolWithCreator() public {
        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens);
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = alice;

        address pool = realFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            ZERO_BYTES32
        );

        PoolRoleAccounts memory vaultRoleAccounts = vault.getPoolRoleAccounts(pool);

        assertEq(vaultRoleAccounts.poolCreator, alice, "Wrong pool creator");
    }

    function testFactoryValidations() public {
        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(sortedTokens);
        TokenConfig[] memory badTokenConfig = new TokenConfig[](3);
        PoolRoleAccounts memory roleAccounts;

        vm.expectRevert(IVaultErrors.MaxTokens.selector);
        realFactory.create(
            name,
            symbol,
            badTokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            ZERO_BYTES32
        );

        priceParams.tokenAPriceIncludesRate = true;

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        realFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            ZERO_BYTES32
        );

        priceParams.tokenAPriceIncludesRate = false;
        priceParams.tokenBPriceIncludesRate = true;

        vm.expectRevert(IVaultErrors.InvalidTokenType.selector);
        realFactory.create(
            name,
            symbol,
            tokenConfig,
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            address(0), // hook contract
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            ZERO_BYTES32
        );
    }
}
