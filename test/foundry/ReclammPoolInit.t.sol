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

    uint256 private constant _INITIAL_PARAMS_ERROR = 1e6;

    uint256 private constant _INITIAL_AMOUNT = 1000e18;

    function setUp() public override {
        super.setUp();

        // This salt produces the address 0xfFFFFaE77e11D7E60F2f0955bd4b21c78F168Ce3.
        // In some tests we want to reproduce 'real' scenarios involving ETHUSD prices. To simplify things and
        // think in those terms, we need the USD token to be the second in the registration order.
        usdc6Decimals = new ERC20TestToken{ salt: bytes32(uint256(15420225402638)) }("USDC-6", "USDC-6", 6);
        usdc6Decimals.mint(lp, DEFAULT_BALANCE);
        vm.startPrank(lp);
        usdc6Decimals.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdc6Decimals), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
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
        initialAmount = bound(initialAmount, 1e18, _INITIAL_AMOUNT);
        rateA = bound(rateA, 1e18, 100e18);
        rateB = bound(rateB, 1e18, 100e18);
        IERC20[] memory sortedTokens = InputHelpers.sortTokens(
            [address(usdc6Decimals), address(wbtc8Decimals)].toMemoryArray().asIERC20()
        );
        _tokenAPriceIncludesRate = tokenAWithRate;
        _tokenBPriceIncludesRate = tokenBWithRate;
        initialAmount = initialAmount / 10 ** (18 - IERC20Metadata(address(sortedTokens[b])).decimals());

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        // Calculate initial balances with rate.
        _rateProviderA.mockRate(rateA);
        _rateProviderB.mockRate(rateB);

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[b],
            initialAmount
        );

        // 0 values are not valid (means that we're adding too little of the lower-price token), and low amounts
        // will result in large rounding errors when computing it in reverse.
        vm.assume(initialBalancesRaw[a] > 10);
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
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        // Spot price is 2.5k ETH/USDC. There are no rate providers here so flags don't really matter.
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

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
        assertApproxEqRel(spotPrice1, spotPrice2, 0.01e16, "Spot prices are not equal");
        assertApproxEqRel(spotPrice1, _initialTargetPrice, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesUsdcEthFlagsTrue() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        // Spot price is 2.5k ETH/USDC. There are no rate providers here so flags don't really matter.
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;
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
        assertApproxEqRel(spotPrice1, spotPrice2, 0.01e16, "Spot prices are not equal");
        assertApproxEqRel(spotPrice1, _initialTargetPrice, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesUsdcWstEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 wstEthRate = 1.2e18;
        uint256 initialUnderlyingPrice = _initialTargetPrice;

        // Spot price for ETH/USDC is 2.5k, so spot price is 3k for wstETH/USDC, i.e. 2.5k * rate.
        _initialTargetPrice = _initialTargetPrice.mulDown(wstEthRate);

        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of wstETH/USDC, so we set both flags to false.
        // wstETH has a rate with respect to ETH.
        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(wstEthRate);
        _rateProviderB.mockRate(FixedPoint.ONE);

        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

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
        // The spot price is always computed in terms of the tokens without the rates, so this would be ETH/USDC
        assertApproxEqRel(spotPrice1, initialUnderlyingPrice, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesUsdcWaEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;

        // Spot price is 2.5k for ETH/USDC --> spot price for waETH/USDC is 2.5k * 1.2
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of ETH/USDC, so we set the flag corresponding to waWeth to true.
        // waWeth has a rate with respect to ETH.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(FixedPoint.ONE);
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

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
        // The actual spot price after initialization corresponds to WETH/USDC, so it matches the initial one.
        assertApproxEqRel(spotPrice1, _initialTargetPrice, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesWaUsdcWaEth() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;
        uint256 waUsdcRate = 1.5e18;

        // Spot price is 2.5k for ETH/USDC --> spot price of waWETH / waUSDC does not matter here.
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of ETH/USDC, both flags to true.
        // waWeth has a rate with respect to ETH, and waUSDC has a rate with respect to USDC.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

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
        // The actual spot price after initialization corresponds to WETH/USDC, so it matches the one specified
        // at creation time.
        assertApproxEqRel(spotPrice1, _initialTargetPrice, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesWaUsdcWaEurc() public {
        uint256 eurUsdRate = 1.17e18;

        address eurc = address(dai); // let's just say this is EURC.
        require(address(usdc6Decimals) > address(eurc), "Incorrect token order");
        uint256 waEurcRate = 1.01e18;
        uint256 waUsdcRate = 1.1e18;

        // Spot price is 1.17 for ETH/USDC --> spot price of waWETH / waUSDC does not matter here.
        _initialMaxPrice = eurUsdRate.mulDown(1.02e18);
        _initialTargetPrice = eurUsdRate;
        _initialMinPrice = eurUsdRate.mulDown(0.98e18);

        IERC20[] memory sortedTokens = [address(eurc), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 eurcIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of ETH/USDC, both flags to true.
        // waWeth has a rate with respect to ETH, and waUSDC has a rate with respect to USDC.
        _tokenAPriceIncludesRate = true;
        _tokenBPriceIncludesRate = true;
        _rateProviderA.mockRate(waEurcRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

        uint256[] memory initialBalancesRaw = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[usdcIndex],
            initialAmount
        );

        // The reference token initial balance should always equal the initial amount passed in.
        assertEq(initialBalancesRaw[usdcIndex], initialAmount, "Invalid initial balance for usdc index");

        uint256[] memory inverseInitialBalances = ReClammPool(newPool).computeInitialBalancesRaw(
            sortedTokens[eurcIndex],
            initialBalancesRaw[eurcIndex]
        );

        // We should get the same result either way.
        assertApproxEqRel(
            initialBalancesRaw[usdcIndex],
            inverseInitialBalances[usdcIndex],
            0.01e16,
            "Wrong inverse initialization balance (usdc)"
        );

        assertApproxEqRel(
            initialBalancesRaw[eurcIndex],
            inverseInitialBalances[eurcIndex],
            0.01e16,
            "Wrong inverse initialization balance (weth)"
        );

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
        // The actual spot price after initialization corresponds to WETH/USDC, so it matches the one specified
        // at creation time.
        assertApproxEqRel(spotPrice1, eurUsdRate, 0.01e16, "Spot prices differ from initial target price");
    }

    function testComputeInitialBalancesWstEthsDai() public {
        require(address(usdc6Decimals) > address(weth), "Incorrect token order");
        uint256 waWethRate = 1.2e18;
        uint256 waUsdcRate = 1.5e18;

        // WETH/DAI is 2.5k
        uint256 initialUnderlyingPrice = _initialTargetPrice;
        _initialTargetPrice = _initialTargetPrice.mulDown(waWethRate).divDown(waUsdcRate);
        // Spot price is 2.5k for ETH/USDC --> spot price for wstETH/sDAI is 2.5k * 1.2 / 1.5 = 2000
        IERC20[] memory sortedTokens = [address(weth), address(usdc6Decimals)].toMemoryArray().asIERC20();
        (uint256 wethIndex, uint256 usdcIndex) = (a, b);

        // We'll specify the spot price in terms of wstEth/sDAI so we'll set both flags to false
        _tokenAPriceIncludesRate = false;
        _tokenBPriceIncludesRate = false;
        _rateProviderA.mockRate(waWethRate);
        _rateProviderB.mockRate(waUsdcRate);
        uint256 initialAmount = 100e6;

        (address newPool, ) = _createPool(sortedTokens.asAddress(), "BeforeInitTest");

        assertFalse(vault.isPoolInitialized(newPool), "Pool is initialized");

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
        // The spot price is always underlying <> underlying, so it has to be 2.5k
        assertApproxEqRel(spotPrice1, initialUnderlyingPrice, 0.01e16, "Spot prices differ from initial target price");
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
