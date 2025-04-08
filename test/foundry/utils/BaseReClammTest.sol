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
    using SafeCast for *;

    uint256 internal constant _INITIAL_PROTOCOL_FEE_PERCENTAGE = 1e16;
    uint256 internal constant _DEFAULT_SWAP_FEE = 0; // 0%
    string internal constant _POOL_VERSION = "ReClamm Pool v1";

    uint256 internal constant _DEFAULT_PRICE_SHIFT_DAILY_RATE = 100e16; // 100%
    uint256 internal constant _DEFAULT_FOURTH_ROOT_PRICE_RATIO = 1.41421356e18; // Price Range of 4 (fourth square root is 1.41)
    uint256 internal constant _DEFAULT_CENTEREDNESS_MARGIN = 20e16; // 20%

    // 0.0001 tokens.
    uint256 internal constant _MIN_TOKEN_BALANCE = 1e14;
    // 1 billion tokens.
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;

    uint96 private _fourthRootPriceRatio = _DEFAULT_FOURTH_ROOT_PRICE_RATIO.toUint96();
    uint256 private _priceShiftDailyRate = _DEFAULT_PRICE_SHIFT_DAILY_RATE;
    uint256[] private _initialBalances = new uint256[](2);

    uint256 internal saltNumber = 0;

    ReClammPoolFactoryMock internal factory;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    uint256 internal _creationTimestamp;

    function setUp() public virtual override {
        if (_initialBalances[0] == 0 && _initialBalances[1] == 0) {
            setInitialBalances(poolInitAmount, poolInitAmount);
        }

        super.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
    }

    function setPriceRatio(uint256 priceRatio) internal {
        priceRatio = Math.sqrt(priceRatio * FixedPoint.ONE);
        _fourthRootPriceRatio = SafeCast.toUint96(Math.sqrt(priceRatio * FixedPoint.ONE));
    }

    function setFourthRootPriceRatio(uint256 endFourthRootPriceRatio) internal {
        _fourthRootPriceRatio = endFourthRootPriceRatio.toUint96();
    }

    function fourthRootPriceRatio() internal view returns (uint256) {
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

    function getTestPoolCreationTimestamp() internal view returns (uint256) {
        return _creationTimestamp;
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
            _DEFAULT_PRICE_SHIFT_DAILY_RATE,
            fourthRootPriceRatio().toUint96(),
            _DEFAULT_CENTEREDNESS_MARGIN.toUint64(),
            bytes32(saltNumber++)
        );
        vm.label(newPool, label);

        _creationTimestamp = block.timestamp;

        // poolArgs is used to check pool deployment address with create2.
        poolArgs = abi.encode(
            ReClammPoolParams({
                name: name,
                symbol: symbol,
                version: _POOL_VERSION,
                priceShiftDailyRate: _DEFAULT_PRICE_SHIFT_DAILY_RATE,
                fourthRootPriceRatio: fourthRootPriceRatio().toUint96(),
                centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN.toUint64()
            }),
            vault
        );
    }

    function initPool() internal virtual override {
        // Let one second pass between creation and initialization.
        vm.warp(block.timestamp + 1);
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
