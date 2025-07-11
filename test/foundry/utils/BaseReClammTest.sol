// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { PoolRoleAccounts, LiquidityManagement } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { PoolFactoryMock } from "@balancer-labs/v3-vault/contracts/test/PoolFactoryMock.sol";
import { RateProviderMock } from "@balancer-labs/v3-vault/contracts/test/RateProviderMock.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { ReClammPoolContractsDeployer } from "./ReClammPoolContractsDeployer.sol";
import { ReClammPool } from "../../../contracts/ReClammPool.sol";
import { a, b } from "../../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactory } from "../../../contracts/ReClammPoolFactory.sol";
import { ReClammPriceParams } from "../../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolParams } from "../../../contracts/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "../../../contracts/test/ReClammPoolMock.sol";
import { ReClammPoolFactoryMock } from "../../../contracts/test/ReClammPoolFactoryMock.sol";

contract BaseReClammTest is ReClammPoolContractsDeployer, BaseVaultTest {
    using FixedPoint for uint256;
    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using SafeCast for *;

    uint256 internal constant _PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT = 124649;

    uint256 internal constant _INITIAL_PROTOCOL_FEE_PERCENTAGE = 1e16;
    uint256 internal constant _DEFAULT_SWAP_FEE = 0.001e16; // minimum swap fee
    string internal constant _POOL_VERSION = "ReClamm Pool v1";

    uint256 internal constant _DEFAULT_MIN_PRICE = 1000e18;
    uint256 internal constant _DEFAULT_MAX_PRICE = 4000e18;
    uint256 internal constant _DEFAULT_TARGET_PRICE = 2500e18;
    uint256 internal constant _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT = 100e16; // 100%
    uint256 internal constant _MAX_DAILY_PRICE_SHIFT_EXPONENT = 100e16; // 300%
    uint64 internal constant _DEFAULT_CENTEREDNESS_MARGIN = 20e16; // 20%

    uint256 internal constant _MIN_PRICE_RATIO_DELTA = 1e6;

    uint256 internal constant _MIN_PRICE = 1e14; // 0.0001
    uint256 internal constant _MAX_PRICE = 1e24; // 1_000_000
    uint256 internal constant _MIN_PRICE_RATIO = 1.1e18;

    // 0.0001 tokens.
    uint256 internal constant _MIN_TOKEN_BALANCE = 1e12;
    // 1 billion tokens.
    uint256 internal constant _MAX_TOKEN_BALANCE = 1e9 * 1e18;

    uint256 private _dailyPriceShiftExponent = _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT;

    uint256[] internal _initialBalances;
    uint256[] internal _initialVirtualBalances;
    uint256 internal _initialFourthRootPriceRatio;
    uint256 internal _initialMinPrice = _DEFAULT_MIN_PRICE;
    uint256 internal _initialMaxPrice = _DEFAULT_MAX_PRICE;
    uint256 internal _initialTargetPrice = _DEFAULT_TARGET_PRICE;

    uint256 internal saltNumber = 0;

    ReClammPoolFactoryMock internal factory;
    RateProviderMock internal _rateProviderA;
    bool internal _tokenAPriceIncludesRate = false;
    RateProviderMock internal _rateProviderB;
    bool internal _tokenBPriceIncludesRate = false;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    uint256 internal _creationTimestamp;

    function setUp() public virtual override {
        _rateProviderA = new RateProviderMock();
        _rateProviderB = new RateProviderMock();

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

    function setDailyPriceShiftExponent(uint256 dailyPriceShiftExponent) internal {
        _dailyPriceShiftExponent = dailyPriceShiftExponent;
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

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: _initialMinPrice,
            initialMaxPrice: _initialMaxPrice,
            initialTargetPrice: _initialTargetPrice,
            tokenAPriceIncludesRate: _tokenAPriceIncludesRate,
            tokenBPriceIncludesRate: _tokenBPriceIncludesRate
        });

        IRateProvider[] memory rateProviders = new IRateProvider[](2);
        rateProviders[a] = _rateProviderA;
        rateProviders[b] = _rateProviderB;

        newPool = ReClammPoolFactoryMock(poolFactory).create(
            name,
            symbol,
            vault.buildTokenConfig(sortedTokens, rateProviders),
            roleAccounts,
            _DEFAULT_SWAP_FEE,
            priceParams,
            _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
            _DEFAULT_CENTEREDNESS_MARGIN,
            bytes32(saltNumber++)
        );
        vm.label(newPool, label);
        // Force the swap fee percentage, even if it's outside the allowed limits.
        setSwapFeePercentage(_DEFAULT_SWAP_FEE);

        _creationTimestamp = block.timestamp;

        // poolArgs is used to check pool deployment address with create2.
        poolArgs = abi.encode(
            ReClammPoolParams({
                name: name,
                symbol: symbol,
                version: _POOL_VERSION,
                initialMinPrice: priceParams.initialMinPrice,
                initialMaxPrice: priceParams.initialMaxPrice,
                initialTargetPrice: priceParams.initialTargetPrice,
                tokenAPriceIncludesRate: priceParams.tokenAPriceIncludesRate,
                tokenBPriceIncludesRate: priceParams.tokenBPriceIncludesRate,
                dailyPriceShiftExponent: _DEFAULT_DAILY_PRICE_SHIFT_EXPONENT,
                centerednessMargin: _DEFAULT_CENTEREDNESS_MARGIN
            }),
            vault
        );
    }

    function initPool() internal virtual override {
        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        _initialBalances = ReClammPool(pool).computeInitialBalancesRaw(dai, poolInitAmount);

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
            vm.assume(newFourthRootPriceRatio - currentFourthRootPriceRatio >= _MIN_PRICE_RATIO_DELTA);
        } else {
            vm.assume(currentFourthRootPriceRatio - newFourthRootPriceRatio >= _MIN_PRICE_RATIO_DELTA);
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

    /**
     * @notice Raise a value to the fourth power (i.e., recover a range limit from its fourth root).
     * @dev Input and output are all 18-decimal floating point numbers.
     * @return limitValue `rootValue` raised to the fourth power
     */
    function _pow4(uint256 rootValue) internal pure returns (uint256) {
        uint256 vSquared = rootValue.mulDown(rootValue);

        return vSquared.mulDown(vSquared);
    }
}
