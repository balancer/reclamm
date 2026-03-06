// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";

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

    uint256 private constant _INITIAL_PARAMS_ERROR = 0.0001e16; // 0.0001% error

    uint256 private constant _INITIAL_AMOUNT = 1000e18;

    address eurc;

    function setUp() public override {
        super.setUp();

        // In some tests we want to reproduce 'real' scenarios involving ETHUSD prices. To simplify things and
        // think in those terms, we need the USD token to be the second in the registration order.
        usdc6Decimals = ERC20TestToken(address(0xfFFFFffFFFFFFfFaFAFaFaFaFAfAfafAfaFaFaFa));
        vm.etch(address(usdc6Decimals), address(new ERC20TestToken("USDC-6", "USDC-6", 6)).code);

        usdc6Decimals.mint(lp, DEFAULT_BALANCE);
        vm.startPrank(lp);
        usdc6Decimals.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdc6Decimals), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        eurc = address(dai); // let's just say this is EURC
    }

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

        assertEq(ReClammPoolMock(pool).computeInitialBalanceRatio(), bOverA, "Wrong initial balance ratio");

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
        uint256 initialBalanceRatio = ReClammPoolMock(pool).computeInitialBalanceRatio();

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

    /// @dev This test uses odd-decimal tokens with rates.
    function testComputeInitialBalances__Fuzz(
        uint256 initialAmount,
        uint256 rateA,
        uint256 rateB,
        bool tokenAWithRate,
        bool tokenBWithRate
    ) public {
        initialAmount = bound(initialAmount, _INITIAL_AMOUNT * 1e6, _INITIAL_AMOUNT * 1e9);
        rateA = bound(rateA, 1e18, 100e18);
        rateB = bound(rateB, 1e18, 100e18);
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(wbtc8Decimals)].toMemoryArray().asIERC20()
        );
        _tokenAPriceIncludesRate = tokenAWithRate;
        _tokenBPriceIncludesRate = tokenBWithRate;
        initialAmount = initialAmount / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());
        // When the flag is set, we'll have a deviation with respect to the initial target price.
        uint256 expectedSpotPrice = _initialTargetPrice
            .mulDown(_tokenAPriceIncludesRate ? rateA : FixedPoint.ONE)
            .divDown(_tokenBPriceIncludesRate ? rateB : FixedPoint.ONE);

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRawGivenB = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmount
        );

        // 0 values are not valid (means that we're adding too little of the lower-price token), and low amounts
        // will result in large rounding errors when computing it in reverse.
        vm.assume(initialBalancesRawGivenB[a] > 10);
        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenB[b], initialAmount, "Invalid initial balance for token B");

        uint256[] memory initialBalancesRawGivenA = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[a],
            initialBalancesRawGivenB[a]
        );

        // We should get the same result either way: computing initial balances given token A or given token B.
        assertApproxEqRel(
            initialBalancesRawGivenB[a],
            initialBalancesRawGivenA[a],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (a)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenB[b],
            initialBalancesRawGivenA[b],
            1e17, // 10% error, since a token with low decimals and a big rate can have a very big error.
            "Wrong inverse initialization balance (b)"
        );

        vm.assume(initialBalancesRawGivenB[a] > 1e6);
        vm.assume(initialBalancesRawGivenB[b] > 1e6);

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenB, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        vm.revertToState(snapshotId);

        _initPool(newPool, initialBalancesRawGivenA, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesUsdcEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        // Spot price is 2.5k ETH/USDC. There are no rate providers here so flags don't really matter.
        uint256 expectedSpotPrice = _initialTargetPrice;
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;

        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(FixedPoint.ONE);
        _rateProviderB.mockRate(FixedPoint.ONE);

        uint256[] memory initialBalancesRawGivenUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWeth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenUsdc[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenUsdc[usdcIndex],
            initialBalancesRawGivenWeth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenUsdc[wethIndex],
            initialBalancesRawGivenWeth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWeth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenWeth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenUsdc, spotPriceGivenWeth, 0.01e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesUsdcEthFlagsTrue() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        // Spot price is 2.5k ETH/USDC. There are no rate providers here so flags don't really matter.
        uint256 expectedSpotPrice = _initialTargetPrice;
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;

        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(FixedPoint.ONE);
        _rateProviderB.mockRate(FixedPoint.ONE);

        uint256[] memory initialBalancesRawGivenUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWeth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenUsdc[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenUsdc[usdcIndex],
            initialBalancesRawGivenWeth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenUsdc[wethIndex],
            initialBalancesRawGivenWeth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWeth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenWeth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenUsdc, spotPriceGivenWeth, 0.01e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesUsdcWstEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 wstEthRate = 1.2e18;

        // Spot price for ETH/USDC is 2.5k, so spot price is 3k for wstETH/USDC, i.e. 2.5k * rate.
        _initialTargetPrice = _initialTargetPrice.mulDown(wstEthRate);
        uint256 expectedSpotPrice = _initialTargetPrice;

        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of wstETH/USDC, so we set both flags to false.
        // wstETH has a rate with respect to ETH.
        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(wstEthRate);
        _rateProviderB.mockRate(FixedPoint.ONE);

        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRawGivenUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWstEth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenUsdc[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenUsdc[usdcIndex],
            initialBalancesRawGivenWstEth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenUsdc[wethIndex],
            initialBalancesRawGivenWstEth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWstEth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenWstEth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenUsdc, spotPriceGivenWstEth, 0.1e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesUsdcWaEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;

        // Spot price is 2.5k for ETH/USDC --> spot price for waETH/USDC is 2.5k * 1.2 = 3000
        uint256 expectedSpotPrice = _initialTargetPrice.mulDown(waWethRate);
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of ETH/USDC, so we set the flag corresponding to waWeth to true.
        // waWeth has a rate with respect to ETH.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(FixedPoint.ONE);
        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRawGivenUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWaEth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenUsdc[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenUsdc[usdcIndex],
            initialBalancesRawGivenWaEth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenUsdc[wethIndex],
            initialBalancesRawGivenWaEth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWaEth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        uint256 spotPriceGivenWaEth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenUsdc, spotPriceGivenWaEth, 0.1e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesWaUsdcWaEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;
        uint256 waUsdcRate = 1.5e18;

        // Spot price is 2.5k for ETH/USDC --> spot price of waWETH / waUSDC is 2.5k * 1.2 / 1.5 = 2000.
        uint256 expectedSpotPrice = _initialTargetPrice.mulDown(waWethRate).divDown(waUsdcRate);
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of ETH/USDC, both flags to true.
        // waWeth has a rate with respect to ETH, and waUSDC has a rate with respect to USDC.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRawGivenWaUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenWaUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWaEth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenWaUsdc[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenWaUsdc[usdcIndex],
            initialBalancesRawGivenWaEth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenWaUsdc[wethIndex],
            initialBalancesRawGivenWaEth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenWaUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenWaUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWaEth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        uint256 spotPriceGivenWaEth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenWaUsdc, spotPriceGivenWaEth, 0.1e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesWaUsdcWaEurc() public {
        uint256 eurUsdRate = 1.17e18;
        require(address(usdc6Decimals) > address(eurc), "Incorrect token order");
        uint256 waEurcRate = 1.01e18;
        uint256 waUsdcRate = 1.1e18;

        // Spot price is 1.17 for EUR/USDC --> spot price of waEUR / waUSDC is 1.17 * 1.01 / 1.1.
        _initialMaxPrice = eurUsdRate.mulDown(1.02e18);
        _initialTargetPrice = eurUsdRate;
        _initialMinPrice = eurUsdRate.mulDown(0.98e18);
        uint256 expectedSpotPrice = _initialTargetPrice.mulDown(waEurcRate).divDown(waUsdcRate);

        IERC20[] memory sortedTokens = [address(eurc), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 eurcIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of EUR/USDC, both flags to true.
        // waEURC has a rate with respect to EURC, and waUSDC has a rate with respect to USDC.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;
        _rateProviderA.mockRate(waEurcRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRawGivenWaUsdc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenWaUsdc[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWaEurc = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[eurcIndex],
            initialBalancesRawGivenWaUsdc[eurcIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenWaUsdc[usdcIndex],
            initialBalancesRawGivenWaEurc[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenWaUsdc[eurcIndex],
            initialBalancesRawGivenWaEurc[eurcIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenWaUsdc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenWaUsdc = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWaEurc, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        uint256 spotPriceGivenWaEurc = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenWaUsdc, spotPriceGivenWaEurc, 0.1e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function testComputeInitialBalancesWstEthsDai() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;
        uint256 waUsdcRate = 1.5e18;

        // WETH/DAI is 2.5k
        // Spot price is 2.5k for ETH/USDC --> spot price for wstETH/sDAI is 2.5k * 1.2 / 1.5 = 2000
        _initialTargetPrice = _initialTargetPrice.mulDown(waWethRate).divDown(waUsdcRate);
        uint256 expectedSpotPrice = _initialTargetPrice;
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of wstEth/sDAI so we'll set both flags to false
        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 10_000_000e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRawGivenSDai = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRawGivenSDai[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory initialBalancesRawGivenWstEth = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[wethIndex],
            initialBalancesRawGivenSDai[wethIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRawGivenSDai[usdcIndex],
            initialBalancesRawGivenWstEth[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRawGivenSDai[wethIndex],
            initialBalancesRawGivenWstEth[wethIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

        // Does not revert either way.
        vm.startPrank(lp);

        uint256 snapshotId = vm.snapshotState();
        _initPool(newPool, initialBalancesRawGivenSDai, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);

        uint256 spotPriceGivenSDai = ReClammPool(newPool).computeCurrentSpotPrice();

        vm.revertToState(snapshotId);
        _initPool(newPool, initialBalancesRawGivenWstEth, 0);
        _validatePostInitConditions(newPool, expectedSpotPrice);
        uint256 spotPriceGivenWstEth = ReClammPool(newPool).computeCurrentSpotPrice();
        assertApproxEqRel(spotPriceGivenSDai, spotPriceGivenWstEth, 0.1e16, "Spot prices are not equal");
        vm.stopPrank();

        _validateActualSpotPrice(newPool);
    }

    function _validatePostInitConditions(address pool, uint256 expectedSpotPrice) private view {
        assertTrue(vault.isPoolInitialized(pool), "Pool is not initialized");

        // Validate price ratio and target.
        (uint256 minPrice, uint256 maxPrice) = ReClammPool(pool).computeCurrentPriceRange();
        ReClammPoolImmutableData memory data = ReClammPool(pool).getReClammPoolImmutableData();
        assertEq(data.initialMinPrice, _initialMinPrice, "Initial min price doesn't match specified one");
        assertEq(data.initialMaxPrice, _initialMaxPrice, "Initial max price doesn't match specified one");
        assertEq(data.initialTargetPrice, _initialTargetPrice, "Initial target price doesn't match specified one");

        assertApproxEqRel(
            maxPrice.divDown(minPrice),
            data.initialMaxPrice.divDown(data.initialMinPrice),
            _INITIAL_PARAMS_ERROR,
            "Wrong price ratio after initialization with rate"
        );

        uint256 spotPrice = ReClammPool(pool).computeCurrentSpotPrice();
        assertApproxEqRel(
            spotPrice,
            expectedSpotPrice,
            _INITIAL_PARAMS_ERROR,
            "Wrong target price after initialization with rate"
        );
    }

    function _validateActualSpotPrice(address pool) private {
        uint256 spotPrice = ReClammPool(pool).computeCurrentSpotPrice();
        IERC20[] memory tokens = vault.getPoolTokens(pool);

        // Spot price is defined as the amount of input tokens required to get a single unit of output token
        // when dismissing price impact.
        // E.g. for an ETH/USDC pool where ETH is token A and USDC is token B, the spot price is how much USDC
        // is needed per unit of ETH.
        // Therefore, token B is token in.
        IERC20 tokenIn = tokens[b];
        IERC20 tokenOut = tokens[a];

        // Use a small amount to minimize price impact (1/100th of a token in raw amounts)
        uint256 smallAmountIn = FixedPoint.ONE / 10 ** (18 - IERC20Metadata(address(tokenIn)).decimals()) / 100;
        uint256 smallAmountOut = FixedPoint.ONE / 10 ** (18 - IERC20Metadata(address(tokenOut)).decimals()) / 100;

        uint256 snapshotId = vm.snapshotState();

        _prankStaticCall();
        uint256 actualAmountOut = router.querySwapSingleTokenExactIn(
            pool,
            tokenIn,
            tokenOut,
            smallAmountIn.mulDown(spotPrice),
            address(this),
            ""
        );
        assertApproxEqRel(
            smallAmountOut,
            actualAmountOut,
            0.01e16,
            "A small test swap does not verify the expected spot price after initialization"
        );

        vm.revertToState(snapshotId);
    }
}
