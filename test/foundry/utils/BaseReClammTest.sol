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
import { a, b } from "../../../contracts/lib/ReClammMath.sol";
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

    uint256 internal constant _DEFAULT_MIN_PRICE = 1000e18;
    uint256 internal constant _DEFAULT_MAX_PRICE = 4000e18;
    uint256 internal constant _DEFAULT_TARGET_PRICE = 2500e18;
    uint256 internal constant _DEFAULT_PRICE_SHIFT_DAILY_RATE = 100e16; // 100%
    uint64 internal constant _DEFAULT_CENTEREDNESS_MARGIN = 20e16; // 20%

    uint256 internal constant _MIN_FOURTH_ROOT_PRICE_RATIO_DELTA = 1e3;

    uint256 internal constant _MIN_PRICE = 1e14; // 0.0001
    uint256 internal constant _MAX_PRICE = 1e24; // 1_000_000
    uint256 internal constant _MIN_PRICE_RATIO = 1.1e18;

    // 0.0001 tokens.
    uint256 internal constant _MIN_TOKEN_BALANCE = 1e12;
    uint256 internal constant _MIN_POOL_CENTEREDNESS = 1e3;
    // 1 billion tokens.
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;

    uint256 private _priceShiftDailyRate = _DEFAULT_PRICE_SHIFT_DAILY_RATE;

    uint256[] internal _initialBalances;
    uint256[] internal _initialVirtualBalances;
    uint256 internal _initialFourthRootPriceRatio;
    uint256 private _initialMinPrice = _DEFAULT_MIN_PRICE;
    uint256 private _initialMaxPrice = _DEFAULT_MAX_PRICE;
    uint256 private _initialTargetPrice = _DEFAULT_TARGET_PRICE;

    uint256 internal saltNumber = 0;

    ReClammPoolFactoryMock internal factory;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    uint256 internal _creationTimestamp;

    function setUp() public virtual override {
        super.setUp();

        (, , _initialBalances, ) = vault.getPoolTokenInfo(pool);
        (_initialVirtualBalances, ) = _computeCurrentVirtualBalances(pool);
        _initialFourthRootPriceRatio = ReClammPool(pool).computeCurrentFourthRootPriceRatio();
    }

    function setInitializationPrices(uint256 newMinPrice, uint256 newMaxPrice, uint256 newTargetPrice) internal {
        _initialMinPrice = newMinPrice;
        _initialMaxPrice = newMaxPrice;
        _initialTargetPrice = newTargetPrice;
    }

    function setPriceShiftDailyRate(uint256 priceShiftDailyRate) internal {
        _priceShiftDailyRate = priceShiftDailyRate;
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
        string memory symbol = "RECLAMM_POOL";

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens.asIERC20());

        PoolRoleAccounts memory roleAccounts;

        roleAccounts = PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: address(0) });

        newPool = ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            vault.buildTokenConfig(sortedTokens),
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            _initialMinPrice,
            _initialMaxPrice,
            _initialTargetPrice,
            _DEFAULT_PRICE_SHIFT_DAILY_RATE,
            _DEFAULT_CENTEREDNESS_MARGIN,
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
                initialMinPrice: _initialMinPrice,
                initialMaxPrice: _initialMaxPrice,
                initialTargetPrice: _initialTargetPrice,
                priceShiftDailyRate: _DEFAULT_PRICE_SHIFT_DAILY_RATE,
                centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN
            }),
            vault
        );
    }

    function initPool() internal virtual override {
        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        uint256 balanceRatio = ReClammPool(pool).computeInitialBalanceRatio();

        _initialBalances = new uint256[](2);

        if (daiIdx < usdcIdx) {
            _initialBalances[daiIdx] = poolInitAmount;
            vm.assume(dai.balanceOf(lp) > _initialBalances[daiIdx]);
            _initialBalances[usdcIdx] = poolInitAmount.mulDown(balanceRatio);
            vm.assume(usdc.balanceOf(lp) > _initialBalances[usdcIdx]);
        } else {
            _initialBalances[usdcIdx] = poolInitAmount;
            vm.assume(usdc.balanceOf(lp) > _initialBalances[usdcIdx]);
            _initialBalances[daiIdx] = poolInitAmount.mulDown(balanceRatio);
            vm.assume(dai.balanceOf(lp) > _initialBalances[daiIdx]);
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

    function _balanceABtoDaiUsdcBalances(
        uint256 balanceA,
        uint256 balanceB
    ) internal view returns (uint256 daiBalance, uint256 usdcBalance) {
        (daiBalance, usdcBalance) = (daiIdx < usdcIdx) ? (balanceA, balanceB) : (balanceB, balanceA);
    }

    function _balanceDaiUsdcToBalances(
        uint256 daiBalance,
        uint256 usdcBalance
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](2);
        (balances[daiIdx], balances[usdcIdx]) = (daiBalance, usdcBalance);
    }

    function _assumeFourthRootPriceRatioDeltaAboveMin(
        uint256 currentFourthRootPriceRatio,
        uint256 newFourthRootPriceRatio
    ) internal pure {
        if (newFourthRootPriceRatio > currentFourthRootPriceRatio) {
            vm.assume(newFourthRootPriceRatio - currentFourthRootPriceRatio >= _MIN_FOURTH_ROOT_PRICE_RATIO_DELTA);
        } else {
            vm.assume(currentFourthRootPriceRatio - newFourthRootPriceRatio >= _MIN_FOURTH_ROOT_PRICE_RATIO_DELTA);
        }
    }

    function _getLastVirtualBalances(address pool) internal view returns (uint256[] memory virtualBalances) {
        virtualBalances = new uint256[](2);
        (virtualBalances[a], virtualBalances[b]) = ReClammPool(pool).getLastVirtualBalances();
    }

    function _computeCurrentVirtualBalances(
        address pool
    ) internal view returns (uint256[] memory currentVirtualBalances, bool changed) {
        currentVirtualBalances = new uint256[](2);
        (currentVirtualBalances[a], currentVirtualBalances[b], changed) = ReClammPool(pool)
            .computeCurrentVirtualBalances();
    }
}
