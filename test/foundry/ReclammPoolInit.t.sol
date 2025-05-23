// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {
    AddLiquidityKind,
    PoolSwapParams,
    RemoveLiquidityKind,
    PoolRoleAccounts
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

import { PriceRatioState, ReClammMath, a, b } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPoolFactoryMock } from "../../contracts/test/ReClammPoolFactoryMock.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";
import { ReClammMathMock } from "../../contracts/test/ReClammMathMock.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import {
    IReClammPool,
    ReClammPoolDynamicData,
    ReClammPoolImmutableData,
    ReClammPoolParams
} from "../../contracts/interfaces/IReClammPool.sol";

contract ReClammPoolInitTest is BaseReClammTest {
    using FixedPoint for uint256;
    using ArrayHelpers for *;
    using CastingHelpers for *;

    uint256 private constant _INITIAL_PARAMS_ERROR = 1e6;

    uint256 private constant _INITIAL_AMOUNT = 1000e18;

    function testComputeInitialBalancesInvalidToken() public {
        vm.expectRevert(IVaultErrors.InvalidToken.selector);
        ReClammPool(pool).computeInitialBalancesRaw(wsteth, _INITIAL_AMOUNT);
    }

    function testInitialBalanceRatioAndBalances() public view {
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        (uint256[] memory realBalances, , , ) = ReClammMath.computeTheoreticalPriceRatioAndBalances(
            data.initialMinPrice,
            data.initialMaxPrice,
            data.initialTargetPrice
        );

        uint256 bOverA = realBalances[b].divDown(realBalances[a]);
        // If the ratio is 1, this isn't testing anything.
        assertNotEq(bOverA, FixedPoint.ONE, "Ratio is 1");

        assertEq(ReClammPool(pool).computeInitialBalanceRatioRaw(), bOverA, "Wrong initial balance ratio");

        IERC20[] memory tokens = vault.getPoolTokens(pool);

        // Compute balances given A.
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(tokens[a], _INITIAL_AMOUNT);
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (A)");
        uint256 expectedAmount = _INITIAL_AMOUNT.mulDown(bOverA);
        assertEq(initialBalancesRaw[b], expectedAmount, "Wrong other token amount (B)");

        // Compute balances given B.
        initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(tokens[b], _INITIAL_AMOUNT);
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Initial amount doesn't match given amount (B)");
        expectedAmount = _INITIAL_AMOUNT.divDown(bOverA);
        assertEq(initialBalancesRaw[a], expectedAmount, "Wrong other token amount (A)");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenA() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            _INITIAL_AMOUNT
        );
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Invalid initial balance for token A");
        assertEq(
            initialBalancesRaw[b],
            _INITIAL_AMOUNT.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenAWithRateA() public {
        uint256 rateA = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            _INITIAL_AMOUNT
        );
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Invalid initial balance for token A");

        assertEq(
            initialBalancesRaw[b],
            _INITIAL_AMOUNT.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenAWithRateB() public {
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenBPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderB.mockRate(rateB);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            _INITIAL_AMOUNT
        );
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Invalid initial balance for token A");

        assertEq(
            initialBalancesRaw[b],
            _INITIAL_AMOUNT.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenAWithRateBoth() public {
        uint256 rateA = 3e18;
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);
        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            _INITIAL_AMOUNT
        );
        assertEq(initialBalancesRaw[a], _INITIAL_AMOUNT, "Invalid initial balance for token A");

        assertEq(
            initialBalancesRaw[b],
            _INITIAL_AMOUNT.mulDown(initialBalanceRatio),
            "Invalid initial balance for token B"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenB() public {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            _INITIAL_AMOUNT
        );
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Invalid initial balance for token B");
        assertEq(
            initialBalancesRaw[a],
            _INITIAL_AMOUNT.divDown(initialBalanceRatio),
            "Invalid initial balance for token A"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenBWithRateA() public {
        uint256 rateA = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            _INITIAL_AMOUNT
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Invalid initial balance for token B");

        // The other token should be the reference / initialBalanceRatio (adjusted for the rate).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertEq(
            initialBalancesRaw[a],
            _INITIAL_AMOUNT.divDown(initialBalanceRatio),
            "Invalid initial balance for token A"
        );

        // Test "inverse" initialization.
        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            _INITIAL_AMOUNT,
            _INITIAL_PARAMS_ERROR,
            "Wrong inverse initialization balance (A)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenBWithRateB() public {
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenBPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            _INITIAL_AMOUNT
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Invalid initial balance for token B");
        // The other token should be the reference / initialBalanceRatio (adjusted for the rate).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertEq(
            initialBalancesRaw[a],
            _INITIAL_AMOUNT.mulDown(rateB),
            "Invalid initial balance for token A"
        );

        // Test "inverse" initialization.
        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            _INITIAL_AMOUNT,
            _INITIAL_PARAMS_ERROR,
            "Wrong inverse initialization balance (B)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    /// @dev This test uses 18-decimal tokens.
    function testComputeInitialBalancesTokenBWithRateBoth() public {
        uint256 rateA = 3e18;
        uint256 rateB = 2e18;
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(tokens);
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;

        (address pool, ) = _createPool(
            [address(sortedTokens[a]), address(sortedTokens[b])].toMemoryArray(),
            "BeforeInitTest"
        );

        assertFalse(vault.isPoolInitialized(pool), "Pool is initialized");

        // Calculate the balance ratio without rate.
        uint256 initialBalanceRatio = ReClammPool(pool).computeInitialBalanceRatioRaw();

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[b],
            _INITIAL_AMOUNT
        );
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], _INITIAL_AMOUNT, "Invalid initial balance for token B");
        // The other token should be the reference / initialBalanceRatio (adjusted for both rates).
        // Note that the balance ratio != price ratio (unless it's perfectly centered).
        assertEq(
            initialBalancesRaw[a],
            _INITIAL_AMOUNT.divDown(initialBalanceRatio),
            "Invalid initial balance for token A"
        );

        uint256[] memory inverseInitialBalances = ReClammPool(pool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );
        // Should be very close to initial amount.
        assertApproxEqRel(
            inverseInitialBalances[b],
            _INITIAL_AMOUNT,
            _INITIAL_PARAMS_ERROR,
            "Wrong inverse initialization balance (AB)"
        );

        // Does not revert
        vm.startPrank(lp);
        _initPool(pool, initialBalancesRaw, 0);

        _validatePostInitConditions();
    }

    /// @dev This test uses odd-decimal tokens with rates.
    function testComputeInitialBalances__Fuzz(
        uint256 initialAmount,
        uint256 rateA,
        uint256 rateB,
        bool tokenAWithRate,
        bool tokenBWithRate
    ) public {
        initialAmount = bound(initialAmount, 1e18, _INITIAL_AMOUNT);
        rateA = bound(rateA, 1e18, 1000e18);
        rateB = bound(rateB, 1e18, 1000e18);
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(wbtc8Decimals)].toMemoryArray().asIERC20()
        );
        if (sortedTokens[a] == usdc6Decimals) {
            console.log('TOKEN A IS USDC; WBTC/USDC');
        } else {
            console.log('TOKEN B IS USDC; USDC/WBTC');
        }
        _tokenAPriceIncludesRate = tokenAWithRate;
        _tokenBPriceIncludesRate = tokenBWithRate;
        initialAmount = initialAmount / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());
        console2.log("initial amount: ", initialAmount);

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        console2.log("initial balance ratio raw:", ReClammPool(newPool).computeInitialBalanceRatioRaw());

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[b], initialAmount, "Invalid initial balance for token B");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRaw[a]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[a],
            inverseInitialBalances[a],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (a)"
        );

        assertApproxEqRel(
            initialBalancesRaw[b],
            inverseInitialBalances[b],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (b)"
        );

        vm.assume(initialBalancesRaw[a] > 1e6);
        vm.assume(initialBalancesRaw[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshot();
        _initPool(newPool, initialBalancesRaw, 0);
        _validatePostInitConditions();
        vm.revertTo(snapshotId);

        _initPool(newPool, inverseInitialBalances, 0);
        _validatePostInitConditions();
    }

    function testComputeInitialBalancesUsdcEth() public {
        // Spot price is 2.5k ETH/USDC
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(weth)].toMemoryArray().asIERC20()
        );
        (uint256 usdcIndex, uint256 wethIndex) = sortedTokens[a] == usdc6Decimals ? (a, b) : (b, a);

        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(FixedPoint.ONE);
        _rateProviderB.mockRate(FixedPoint.ONE);

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRaw[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[usdcIndex],
            inverseInitialBalances[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRaw[wethIndex],
            inverseInitialBalances[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        vm.assume(initialBalancesRaw[a] > 1e6);
        vm.assume(initialBalancesRaw[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshot();
        _initPool(newPool, initialBalancesRaw, 0);
        _validatePostInitConditions();

        uint256 spotPrice1 = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertTo(snapshotId);
        _initPool(newPool, inverseInitialBalances, 0);
        _validatePostInitConditions();

        uint256 spotPrice2 = ReClammPool(newPool).computeCurrentSpotPrice();
        assertEq(spotPrice1, spotPrice2, "Spot prices are not equal");
        assertApproxEqRel(spotPrice1, _initialTargetPrice, 0.01e16, "Spot prices differ from initial target price");

        console2.log("Initial balance USDC: ", initialBalancesRaw[usdcIndex]);
        console2.log("Initial balance waWETH: ", initialBalancesRaw[wethIndex]);
        console2.log("spot price: ", spotPrice2);
    }

    function testComputeInitialBalancesUsdcWstEth() public {
        // Spot price is 3k wstETH/USDC --> spot price for ETH/USDC is 3k/1.2
        _initialTargetPrice = _initialTargetPrice.mulDown(1.2e18);

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(weth)].toMemoryArray().asIERC20()
        );
        (uint256 usdcIndex, uint256 wethIndex) = sortedTokens[a] == usdc6Decimals ? (a, b) : (b, a);

        if (usdcIndex == a) {
            _tokenAPriceIncludesRate = false;
            _tokenBPriceIncludesRate = false;
            _rateProviderA.mockRate(FixedPoint.ONE);
            _rateProviderB.mockRate(1.2e18);
        } else {
            _tokenAPriceIncludesRate = false;
            _tokenBPriceIncludesRate = false;
            _rateProviderA.mockRate(1.2e18);
            _rateProviderB.mockRate(FixedPoint.ONE);
        }
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        console2.log("Initial balance USDC: ", initialBalancesRaw[usdcIndex]);
        console2.log("Initial balance waWETH: ", initialBalancesRaw[wethIndex]);

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRaw[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[usdcIndex],
            inverseInitialBalances[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRaw[wethIndex],
            inverseInitialBalances[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        vm.assume(initialBalancesRaw[a] > 1e6);
        vm.assume(initialBalancesRaw[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshot();
        _initPool(newPool, initialBalancesRaw, 0);
        _validatePostInitConditions();

        uint256 spotPrice1 = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertTo(snapshotId);
        _initPool(newPool, inverseInitialBalances, 0);
        _validatePostInitConditions();
        uint256 spotPrice2 = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPrice1, spotPrice2, 0.1e16, "Spot prices are not equal");
        // assertApproxEqRel(spotPrice1, _initialTargetPrice.mulDown(1.2e18), 0.01e16, "Spot prices differ from initial target price");
        console2.log("spot price: ", spotPrice2);
    }

    function testComputeInitialBalancesUsdcWaEth() public {
        console.log("TEST START");
        // Spot price is 2.5k ETH/USDC --> spot price for waETH/USDC is 2.5k * 1.2

        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(weth)].toMemoryArray().asIERC20()
        );
        (uint256 usdcIndex, uint256 wethIndex) = sortedTokens[a] == usdc6Decimals ? (a, b) : (b, a);

        if (usdcIndex == a) {
            console.log("USDC IS A");
            _tokenAPriceIncludesRate = false;
            _tokenBPriceIncludesRate = true;
            _rateProviderA.mockRate(FixedPoint.ONE);
            _rateProviderB.mockRate(1.2e18);
        } else {
            console.log("WETH IS A");
            _tokenAPriceIncludesRate = true;
            _tokenBPriceIncludesRate = false;
            _rateProviderA.mockRate(1.2e18);
            _rateProviderB.mockRate(FixedPoint.ONE);
        }
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        console2.log("Initial balance USDC: ", initialBalancesRaw[usdcIndex]);
        console2.log("Initial balance waWETH: ", initialBalancesRaw[wethIndex]);

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRaw[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[usdcIndex],
            inverseInitialBalances[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRaw[wethIndex],
            inverseInitialBalances[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        vm.assume(initialBalancesRaw[a] > 1e6);
        vm.assume(initialBalancesRaw[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshot();
        _initPool(newPool, initialBalancesRaw, 0);
        _validatePostInitConditions();

        uint256 spotPrice1 = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertTo(snapshotId);
        _initPool(newPool, inverseInitialBalances, 0);
        _validatePostInitConditions();
        uint256 spotPrice2 = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPrice1, spotPrice2, 0.1e16, "Spot prices are not equal");
        // assertApproxEqRel(spotPrice1, _initialTargetPrice.mulDown(1.2e18), 0.01e16, "Spot prices differ from initial target price");
        console2.log("spot price: ", spotPrice2);
    }

    function _validatePostInitConditions() private view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");

        // Validate price ratio and target.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();

        assertApproxEqRel(
            maxPrice.divDown(minPrice),
            data.initialMaxPrice.divDown(data.initialMinPrice),
            _INITIAL_PARAMS_ERROR,
            "Wrong price ratio after initialization with rate"
        );

        uint256 targetPrice = ReClammPool(pool).computeCurrentSpotPrice();
        assertApproxEqRel(
            targetPrice,
            data.initialTargetPrice,
            _INITIAL_PARAMS_ERROR,
            "Wrong target price after initialization with rate"
        );
    }
}
