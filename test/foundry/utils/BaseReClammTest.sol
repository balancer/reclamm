// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { PoolRoleAccounts, LiquidityManagement } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { PoolFactoryMock } from "@balancer-labs/v3-vault/contracts/test/PoolFactoryMock.sol";
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
    string internal constant _POOL_VERSION = "ReClamm Pool v1";

    uint256 internal constant _DEFAULT_MIN_PRICE = 1000e18;
    uint256 internal constant _DEFAULT_MAX_PRICE = 4000e18;
    uint256 internal constant _DEFAULT_TARGET_PRICE = 2500e18;
    uint256 internal constant _DEFAULT_PRICE_SHIFT_DAILY_RATE = 100e16; // 100%
    uint64 internal constant _DEFAULT_CENTEREDNESS_MARGIN = 20e16; // 20%
    uint256 internal defaultFourthRootPriceRatio;

    // 0.0001 tokens.
    uint256 internal constant _MIN_TOKEN_BALANCE = 1e14;
    // 1 billion tokens.
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;

    uint96 private _fourthRootPriceRatio;
    uint256 private _priceShiftDailyRate = _DEFAULT_PRICE_SHIFT_DAILY_RATE;
    uint256[] private _initialBalances = new uint256[](2);

    uint256 internal saltNumber = 0;

    ReClammPoolFactoryMock internal factory;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    function setUp() public virtual override {
        super.setUp();

        defaultFourthRootPriceRatio = Math.sqrt(
            Math.sqrt((_DEFAULT_MAX_PRICE * FixedPoint.ONE).divDown(_DEFAULT_MIN_PRICE)) * FixedPoint.ONE
        );
    }

    function setPriceRatio(uint256 priceRatio) internal {
        priceRatio = Math.sqrt(priceRatio * FixedPoint.ONE);
        _fourthRootPriceRatio = SafeCast.toUint96(Math.sqrt(priceRatio * FixedPoint.ONE));
    }

    function setFourthRootPriceRatio(uint96 endFourthRootPriceRatio) internal {
        _fourthRootPriceRatio = endFourthRootPriceRatio;
    }

    function fourthRootPriceRatio() internal view returns (uint96) {
        return _fourthRootPriceRatio;
    }

    function setPriceShiftDailyRate(uint256 priceShiftDailyRate) internal {
        _priceShiftDailyRate = priceShiftDailyRate;
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
        string memory name = "ReClamm Pool";
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
            _DEFAULT_MIN_PRICE,
            _DEFAULT_MAX_PRICE,
            _DEFAULT_TARGET_PRICE,
            _DEFAULT_PRICE_SHIFT_DAILY_RATE,
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
                initialMinPrice: _DEFAULT_MIN_PRICE,
                initialMaxPrice: _DEFAULT_MAX_PRICE,
                initialTargetPrice: _DEFAULT_TARGET_PRICE,
                priceShiftDailyRate: _DEFAULT_PRICE_SHIFT_DAILY_RATE,
                centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN
            }),
            vault
        );
    }

    function initPool() internal virtual override {
        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        uint256 proportion = ReClammPool(pool).getInitializationProportion();

        if (daiIdx < usdcIdx) {
            _initialBalances[daiIdx] = poolInitAmount;
            _initialBalances[usdcIdx] = poolInitAmount.mulDown(proportion);
        }

        vm.startPrank(lp);
        _initPool(pool, _initialBalances, 0);
        vm.stopPrank();
    }

    function _setPoolBalances(
        uint256 daiBalance,
        uint256 usdcBalance
    ) internal returns (uint256[] memory newPoolBalances) {
        newPoolBalances = new uint256[](2);
        newPoolBalances[daiIdx] = daiBalance;
        newPoolBalances[usdcIdx] = usdcBalance;

        vault.manualSetPoolBalances(pool, newPoolBalances, newPoolBalances);
    }
}
