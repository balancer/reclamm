// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v3-vault/test/foundry/utils/BaseMedusaTest.sol";

import { ReClammPoolFactory } from "../../contracts/ReClammPoolFactory.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";

contract SwapReClammMedusaTest is BaseMedusaTest {
    using FixedPoint for uint256;
    using CastingHelpers for *;

    uint256 internal constant MIN_SWAP_AMOUNT = 1e6;
    uint256 constant MAX_IN_RATIO = 0.3e18;

    int256 internal initInvariant;

    constructor() BaseMedusaTest() {
        initInvariant = computeInvariant();
        vault.manuallySetSwapFee(address(pool), 0);

        emit Debug("prevInvariant", initInvariant);
    }

    function createPool(IERC20[] memory tokens, uint256[] memory initialBalances) internal override returns (address) {
        ReClammPoolFactory factory = new ReClammPoolFactory(
            vault,
            1 days,
            "ReClamm Pool Factory",
            "ReClammPoolFactory"
        );

        PoolRoleAccounts memory roleAccounts;
        address newPool = ReClammPoolFactory(factory).create(
            "ReClamm Pool",
            "RECLAMM",
            vault.buildTokenConfig(tokens),
            roleAccounts,
            0,
            1000e18, // 1000 min price
            4000e18, // 4000 max price
            3000e18, // 3000 target price
            1e18, // 100% price shift daily rate
            10e16, // 10% margin
            ""
        );

        // Compute the initial balance ratio so that the target price of the pool is respected.
        initialBalances[1] = initialBalances[0].mulDown(ReClammPool(newPool).computeInitialBalanceRatio());

        // Initialize liquidity of new pool.
        medusa.prank(lp);
        router.initialize(address(newPool), tokens, initialBalances, 0, false, bytes(""));

        return newPool;
    }

    function getTokensAndInitialBalances()
        internal
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

    function optimize_currentInvariant() public view returns (int256) {
        return -int256(computeInvariant());
    }

    function property_currentInvariant() public returns (bool) {
        int256 currentInvariant = computeInvariant();
        return currentInvariant >= initInvariant;
    }

    function computeSwapExactIn(uint256 tokenIndexIn, uint256 tokenIndexOut, uint256 exactAmountIn) public {
        (tokenIndexIn, tokenIndexOut) = boundTokenIndexes(tokenIndexIn, tokenIndexOut);

        exactAmountIn = boundSwapAmount(exactAmountIn, tokenIndexIn);

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(address(pool));

        emit Debug("token index in", tokenIndexIn);
        emit Debug("token index out", tokenIndexOut);
        emit Debug("exact amount in", exactAmountIn);

        medusa.prank(alice);
        router.swapSingleTokenExactIn(
            address(pool),
            tokens[tokenIndexIn],
            tokens[tokenIndexOut],
            exactAmountIn,
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        emit Debug("currentInvariant", computeInvariant());
    }

    function computeSwapExactOut(uint256 tokenIndexIn, uint256 tokenIndexOut, uint256 exactAmountOut) public {
        (tokenIndexIn, tokenIndexOut) = boundTokenIndexes(tokenIndexIn, tokenIndexOut);

        exactAmountOut = boundSwapAmount(exactAmountOut, tokenIndexOut);

        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(address(pool));

        emit Debug("token index in", tokenIndexIn);
        emit Debug("token index out", tokenIndexOut);
        emit Debug("exact amount out", exactAmountOut);

        medusa.prank(alice);
        router.swapSingleTokenExactOut(
            address(pool),
            tokens[tokenIndexIn],
            tokens[tokenIndexOut],
            exactAmountOut,
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        emit Debug("currentInvariant", computeInvariant());
    }

    function computeInvariant() internal view returns (int256) {
        (, , , uint256[] memory lastBalancesLiveScaled18) = vault.getPoolTokenInfo(address(pool));
        return int256(pool.computeInvariant(lastBalancesLiveScaled18, Rounding.ROUND_UP));
    }

    function boundTokenIndexes(
        uint256 tokenIndexInRaw,
        uint256 tokenIndexOutRaw
    ) internal view returns (uint256 tokenIndexIn, uint256 tokenIndexOut) {
        uint256 len = vault.getPoolTokens(address(pool)).length;

        tokenIndexIn = bound(tokenIndexInRaw, 0, 1);
        tokenIndexOut = tokenIndexIn == 0 ? 1 : 0;
    }

    function boundSwapAmount(
        uint256 tokenAmountIn,
        uint256 tokenIndex
    ) internal view returns (uint256 boundedAmountIn) {
        (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(address(pool));
        boundedAmountIn = bound(tokenAmountIn, MIN_SWAP_AMOUNT, balancesRaw[tokenIndex].mulDown(MAX_IN_RATIO));
    }
}
