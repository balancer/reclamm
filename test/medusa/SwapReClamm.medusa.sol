// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-vault/test/foundry/utils/BaseMedusaTest.sol";

import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { ReClammMath } from "../../contracts/lib/ReClammMath.sol";
import { ReClammPriceParams } from "../../../contracts/lib/ReClammPoolFactoryLib.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { ReClammPoolMock } from "../../contracts/test/ReClammPoolMock.sol";

/**
 * @notice Medusa test for the ReClamm pool.
 * @dev We compute an initial invariant, and then it calls `optimize_invariant` with random sequences of operations,
 * mainly ensuring that the invariant can never decrease.
 */
contract SwapReClammMedusaTest is BaseMedusaTest {
    using FixedPoint for uint256;
    using ArrayHelpers for *;

    uint256 internal constant MIN_SWAP_AMOUNT = 1e6;
    uint256 constant MAX_OUT_RATIO = FixedPoint.ONE; // 100%
    uint256 constant MIN_RECLAMM_TOKEN_BALANCE = 1e12;

    uint256 internal invariantProportion = FixedPoint.ONE; // 100%

    uint256 internal immutable initInvariant;

    constructor() BaseMedusaTest() {
        initInvariant = computeInvariant();
        vault.manualUnsafeSetStaticSwapFeePercentage(address(pool), 0);

        emit Debug("prevInvariant", initInvariant);
    }

    function createPool(IERC20[] memory tokens, uint256[] memory initialBalances) internal override returns (address) {
        ReClammPoolFactory factory = new ReClammPoolFactory(
            vault,
            1 days,
            "ReClamm Pool Factory",
            "ReClammPoolFactory"
        );

        ReClammPriceParams memory priceParams = ReClammPriceParams({
            initialMinPrice: 1000e18, // 1000 min price
            initialMaxPrice: 4000e18, // 4000 max price
            initialTargetPrice: 3000e18, // 3000 target price
            tokenAPriceIncludesRate: false, // Do not consider rates in the price calculation for token A
            tokenBPriceIncludesRate: false // Do not consider rates in the price calculation for token B
        });

        PoolRoleAccounts memory roleAccounts;
        address newPool = ReClammPoolFactory(factory).create(
            "ReClamm Pool",
            "RECLAMM",
            vault.buildTokenConfig(tokens),
            roleAccounts,
            0, // swap fee
            address(0), // hook contract
            priceParams,
            1e18, // 100% daily price shift exponent
            10e16, // 10% margin
            ""
        );

        // Compute the initial balance ratio so that the target price of the pool is respected.
        initialBalances[1] = initialBalances[0].mulDown(ReClammPoolMock(newPool).computeInitialBalanceRatio());

        // Initialize liquidity of new pool.
        medusa.prank(lp);
        router.initialize(address(newPool), tokens, initialBalances, 0, false, bytes(""));

        return newPool;
    }

    function getTokensAndInitialBalances()
        internal
        view
        override
        returns (IERC20[] memory tokens, uint256[] memory initialBalances)
    {
        tokens = new IERC20[](2);
        tokens[0] = dai;
        tokens[1] = usdc;
        tokens = InputHelpers.sortTokens(tokens);

        // Initial balances will be recalculated in createPool. (We need the pool created to compute the proportion
        // of usdc in terms of dai).
        initialBalances = new uint256[](2);
        initialBalances[0] = DEFAULT_INITIAL_POOL_BALANCE;
        initialBalances[1] = DEFAULT_INITIAL_POOL_BALANCE;
    }

    function optimize_currentInvariant() public returns (int256) {
        uint256 currentInvariant = Math.sqrt(computeInvariant() * FixedPoint.ONE);
        uint256 initialInvariant = Math.sqrt(initInvariant * FixedPoint.ONE).mulUp(invariantProportion);

        // Checking invariant property here, and not in a proper "property_" function, because Medusa reverts silently.
        if (currentInvariant < initialInvariant) {
            revert();
        }

        emit Debug("initInvariant   ", initialInvariant);
        emit Debug("currentInvariant", currentInvariant);

        return -int256(currentInvariant);
    }

    // Computing exact in with amount out, because the medusa test stops if a contract reverts (even inside a
    // try/catch block).
    function computeSwapExactIn(uint8 tokenInIndex, uint256 exactAmountOut) public {
        uint256 tokenIndexIn = tokenInIndex < uint8(128) ? 0 : 1;
        uint256 tokenIndexOut = tokenInIndex < uint8(128) ? 1 : 0;

        exactAmountOut = boundSwapAmountOut(exactAmountOut, tokenIndexOut);

        // Make sure medusa does not stop if the pool reverts due to lack of liquidity.
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        if (balances[tokenIndexOut] - exactAmountOut < MIN_RECLAMM_TOKEN_BALANCE) {
            return;
        }

        (uint256 virtualBalanceA, uint256 virtualBalanceB, ) = ReClammPool(address(pool))
            .computeCurrentVirtualBalances();

        uint256 exactAmountIn = ReClammMath.computeInGivenOut(
            balances,
            virtualBalanceA,
            virtualBalanceB,
            tokenIndexIn,
            tokenIndexOut,
            exactAmountOut
        );

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(address(pool));

        emit Debug("token index in", tokenIndexIn);
        emit Debug("token index out", tokenIndexOut);
        emit Debug("exact amount in", exactAmountIn);

        medusa.prank(alice);
        try
            router.swapSingleTokenExactIn(
                address(pool),
                tokens[tokenIndexIn],
                tokens[tokenIndexOut],
                exactAmountIn,
                0,
                MAX_UINT256,
                false,
                bytes("")
            )
        {
            emit Debug("currentInvariant", computeInvariant());
        } catch {}
    }

    function computeSwapExactOut(uint8 tokenInIndex, uint256 exactAmountOut) public {
        uint256 tokenIndexIn = tokenInIndex < uint8(128) ? 0 : 1;
        uint256 tokenIndexOut = tokenInIndex < uint8(128) ? 1 : 0;

        exactAmountOut = boundSwapAmountOut(exactAmountOut, tokenIndexOut);

        // Make sure medusa does not stop if the pool reverts due to lack of liquidity.
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        if (balances[tokenIndexOut] - exactAmountOut < MIN_RECLAMM_TOKEN_BALANCE) {
            return;
        }

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(address(pool));

        emit Debug("token index in", tokenIndexIn);
        emit Debug("token index out", tokenIndexOut);
        emit Debug("exact amount out", exactAmountOut);

        medusa.prank(alice);
        try
            router.swapSingleTokenExactOut(
                address(pool),
                tokens[tokenIndexIn],
                tokens[tokenIndexOut],
                exactAmountOut,
                MAX_UINT256,
                MAX_UINT256,
                false,
                bytes("")
            )
        {
            emit Debug("currentInvariant", computeInvariant());
        } catch {}
    }

    function computeAddLiquidity(uint256 exactBptOut) public {
        uint256 oldTotalSupply = ReClammPool(address(pool)).totalSupply();
        exactBptOut = bound(exactBptOut, 1e18, oldTotalSupply);

        medusa.prank(lp);
        router.addLiquidityProportional(
            address(pool),
            [MAX_UINT256, MAX_UINT256].toMemoryArray(),
            exactBptOut,
            false,
            bytes("")
        );

        uint256 newTotalSupply = ReClammPool(address(pool)).totalSupply();
        uint256 proportion = newTotalSupply.divDown(oldTotalSupply);
        invariantProportion = invariantProportion.mulDown(proportion);
    }

    function computeRemoveLiquidity(uint256 exactBptIn) public {
        uint256 oldTotalSupply = ReClammPool(address(pool)).totalSupply();
        exactBptIn = bound(exactBptIn, 1e18, oldTotalSupply);
        uint256 proportion = (oldTotalSupply - exactBptIn).divDown(oldTotalSupply);

        // Make sure medusa does not stop if the pool reverts due to lack of liquidity.
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        if (
            balances[0].mulDown(proportion) < MIN_RECLAMM_TOKEN_BALANCE ||
            balances[1].mulDown(proportion) < MIN_RECLAMM_TOKEN_BALANCE
        ) {
            return;
        }

        medusa.prank(lp);
        router.removeLiquidityProportional(
            address(pool),
            exactBptIn,
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        invariantProportion = invariantProportion.mulDown(proportion);
    }

    function computeInvariant() internal view returns (uint256) {
        (, , , uint256[] memory lastBalancesLiveScaled18) = vault.getPoolTokenInfo(address(pool));
        return pool.computeInvariant(lastBalancesLiveScaled18, Rounding.ROUND_UP);
    }

    function boundSwapAmountOut(
        uint256 tokenAmountOut,
        uint256 tokenOutIndex
    ) internal view returns (uint256 boundedAmountOut) {
        (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(address(pool));
        boundedAmountOut = bound(tokenAmountOut, MIN_SWAP_AMOUNT, balancesRaw[tokenOutIndex].mulDown(MAX_OUT_RATIO));
    }
}
