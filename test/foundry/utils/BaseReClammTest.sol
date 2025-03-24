// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { PoolRoleAccounts, LiquidityManagement } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { PoolFactoryMock } from "@balancer-labs/v3-vault/contracts/test/PoolFactoryMock.sol";
import { GyroPoolMath } from "@balancer-labs/v3-pool-gyro/contracts/lib/GyroPoolMath.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { ReClammPoolContractsDeployer } from "./ReClammPoolContractsDeployer.sol";
import { ReClammPool } from "../../../contracts/ReClammPool.sol";
import { ReClammPoolFactory } from "../../../contracts/ReClammPoolFactory.sol";
import { ReClammPoolParams } from "../../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../../contracts/test/ReClammPoolMock.sol";
import { ReClammPoolFactoryMock } from "../../../contracts/test/ReClammPoolFactoryMock.sol";

contract BaseReClammTest is ReClammPoolContractsDeployer, BaseVaultTest {
    using FixedPoint for uint256;
    using CastingHelpers for address[];
    using ArrayHelpers for *;

    uint256 internal constant _INITIAL_PROTOCOL_FEE_PERCENTAGE = 1e16;
    uint256 internal constant _DEFAULT_SWAP_FEE = 0; // 0%
    string internal constant _POOL_VERSION = "Acl Amm Pool v1";

    uint256 internal constant _DEFAULT_INCREASE_DAY_RATE = 100e16; // 100%
    uint96 internal constant _DEFAULT_SQRT_PRICE_RATIO = 1.41421356e18; // Price Range of 4 (fourth square root is 1.41)
    uint256 internal constant _DEFAULT_CENTEREDNESS_MARGIN = 10e16; // 10%

    uint96 private _sqrtPriceRatio = _DEFAULT_SQRT_PRICE_RATIO;
    uint256 private _increaseDayRate = _DEFAULT_INCREASE_DAY_RATE;
    uint256[] private _initialBalances = new uint256[](2);

    uint256 internal saltNumber = 0;

    ReClammPoolFactoryMock internal factory;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    function setUp() public virtual override {
        if (_initialBalances[0] == 0 && _initialBalances[1] == 0) {
            setInitialBalances(poolInitAmount, poolInitAmount);
        }

        super.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
    }

    function setPriceRange(uint256 priceRange) internal {
        uint256 priceRatio = GyroPoolMath.sqrt(priceRange, 5);
        _sqrtPriceRatio = SafeCast.toUint96(GyroPoolMath.sqrt(priceRatio, 5));
    }

    function setSqrtPriceRatio(uint96 newSqrtPriceRatio) internal {
        _sqrtPriceRatio = newSqrtPriceRatio;
    }

    function sqrtPriceRatio() internal view returns (uint96) {
        return _sqrtPriceRatio;
    }

    function setIncreaseDayRate(uint256 increaseDayRate) internal {
        _increaseDayRate = increaseDayRate;
    }

    function setInitialBalances(uint256 aBalance, uint256 bBalance) internal {
        _initialBalances[0] = aBalance;
        _initialBalances[1] = bBalance;
    }

    function initialBalances() internal view returns (uint256[] memory) {
        return _initialBalances;
    }

    function createPoolFactory() internal override returns (address) {
        factory = deployReClammPoolFactoryMock(vault, 365 days, "Factory v1", _POOL_VERSION);
        vm.label(address(factory), "Acl Amm Factory");

        return address(factory);
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        string memory name = "Acl Amm Pool";
        string memory symbol = "RECLAMMPOOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: address(0) });

        newPool = ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            vault.buildTokenConfig(sortedTokens),
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            _DEFAULT_INCREASE_DAY_RATE,
            sqrtPriceRatio(),
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
        vm.label(newPool, label);

        // poolArgs is used to check pool deployment address with create2.
        poolArgs = abi.encode(
            ReClammPoolParams({
                name: name,
                symbol: symbol,
                version: _POOL_VERSION,
                increaseDayRate: _DEFAULT_INCREASE_DAY_RATE,
                sqrtPriceRatio: sqrtPriceRatio(),
                centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN
            }),
            vault
        );
    }

    function initPool() internal virtual override {
        vm.startPrank(lp);
        _initPool(pool, _initialBalances, 0);
        vm.stopPrank();
    }
}
