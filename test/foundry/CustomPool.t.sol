// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {
    PoolRoleAccounts,
    PoolSwapParams,
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { CustomPoolFactory } from "../../contracts/CustomPoolFactory.sol";
import { CustomPool } from "../../contracts/CustomPool.sol";

contract CustomPoolTest is BaseVaultTest {
    using CastingHelpers for address[];

    uint256 constant _MIN_NUM_TOKENS = 2;
    uint256 constant _MAX_NUM_TOKENS = 8;
    uint256 constant _DEFAULT_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    string constant _FACTORY_VERSION = "v1.0.0";
    string constant _POOL_VERSION = "v1.0.0";

    CustomPoolFactory private _factory;

    function createPoolFactory() internal override returns (address) {
        _factory = new CustomPoolFactory(vault, 365 days, _FACTORY_VERSION, _POOL_VERSION);
        vm.label(address(_factory), "Custom Pool Factory");

        return address(_factory);
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        PoolRoleAccounts memory roleAccounts;

        newPool = _factory.create(
            "Custom Pool",
            "CP",
            vault.buildTokenConfig(tokens.asIERC20()),
            roleAccounts,
            _DEFAULT_SWAP_FEE_PERCENTAGE,
            address(0), // No hooks
            false, // Donation disabled
            false, // Unbalanced liquidity disabled
            bytes32(0)
        );
        vm.label(newPool, label);

        poolArgs = abi.encode(vault, "Custom Pool", "CP", _POOL_VERSION);
    }

    function testOnSwap__Fuzz(
        uint256 amountGivenScaled18,
        uint256[] memory balancesScaled18,
        uint256 tokenInIndex,
        uint256 tokenOutIndex,
        uint256 numTokens
    ) public view {
        numTokens = bound(numTokens, _MIN_NUM_TOKENS, _MAX_NUM_TOKENS);
        tokenInIndex = bound(tokenInIndex, 0, numTokens - 1);
        tokenOutIndex = bound(tokenOutIndex, 0, numTokens - 1);
        vm.assume(tokenInIndex != tokenOutIndex);

        amountGivenScaled18 = bound(amountGivenScaled18, 1e6, DEFAULT_AMOUNT);
        balancesScaled18 = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            balancesScaled18[i] = bound(balancesScaled18[i], 1e6, DEFAULT_AMOUNT);
        }

        uint256 amountReceivedScaled18 = CustomPool(pool).onSwap(
            PoolSwapParams({
                kind: SwapKind.EXACT_IN,
                amountGivenScaled18: amountGivenScaled18,
                balancesScaled18: balancesScaled18,
                indexIn: tokenInIndex,
                indexOut: tokenOutIndex,
                router: address(this),
                userData: bytes("")
            })
        );

        assertEq(
            amountReceivedScaled18,
            amountGivenScaled18,
            "Amount received should be equal to amount given in a linear pool"
        );
    }
}
