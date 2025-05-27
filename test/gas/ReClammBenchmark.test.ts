/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract, toBeHex } from 'ethers';
import { ethers } from 'hardhat';
import { deploy, deployedAt } from '@balancer-labs/v3-helpers/src/contract';
import { advanceTime, currentTimestamp, DAY, HOUR, MONTH } from '@balancer-labs/v3-helpers/src/time';
import { buildTokenConfig } from '@balancer-labs/v3-helpers/src/models/tokens/tokenConfig';
import * as expectEvent from '@balancer-labs/v3-helpers/src/test/expectEvent';

import { Benchmark, PoolTag, PoolInfo, TestsSwapHooks } from '@balancer-labs/v3-benchmarks/src/PoolBenchmark.behavior';
import { MAX_UINT256, ZERO_ADDRESS, ZERO_BYTES32 } from '@balancer-labs/v3-helpers/src/constants';

import { PoolRoleAccountsStruct } from '../../typechain-types/@balancer-labs/v3-vault/contracts/Vault';
import { ReClammPoolFactory } from '../../typechain-types/contracts/ReClammPoolFactory';
import { ReClammPool } from '../../typechain-types/contracts/ReClammPool';
import { fp } from '@balancer-labs/v3-helpers/src/numbers';
import { saveSnap } from '@balancer-labs/v3-helpers/src/gas';
import { sharedBeforeEach } from '../../lib/balancer-v3-monorepo/pvt/common/sharedBeforeEach';

class ReClammBenchmark extends Benchmark {
  counter = 0;

  constructor(dirname: string) {
    super(dirname, 'ReClamm', {
      disableNestedPoolTests: true,
      disableDonationTests: true,
      disableUnbalancedLiquidityTests: true,
      enableCustomSwapTests: true,
    });
  }

  override async deployPool(tag: PoolTag, poolTokens: string[], withRate: boolean): Promise<PoolInfo> {
    const [, , swapFeeManager] = await ethers.getSigners();

    const factory = (await deploy('ReClammPoolFactory', {
      args: [await this.vault.getAddress(), MONTH * 12, 'Factory v1', 'Pool v1'],
    })) as unknown as ReClammPoolFactory;

    const roleAccounts: PoolRoleAccountsStruct = {
      poolCreator: ZERO_ADDRESS,
      pauseManager: ZERO_ADDRESS,
      swapFeeManager: swapFeeManager,
    };

    const salt = toBeHex(this.counter++, 32);

    const priceParams: ReClammPoolFactory.ReClammPriceParamsStruct = {
      initialMinPrice: fp(0.5), // 0.5 min price
      initialMaxPrice: fp(2), // 2 max price
      initialTargetPrice: fp(1), // 1 target price
      tokenAPriceIncludesRate: false, // Do not consider rates in the price calculation for token A
      tokenBPriceIncludesRate: false, // Do not consider rates in the price calculation for token B
    };

    // The min, max and target prices were chosen to make sure the balance of token 1 is equal to balance of token 0.
    const tx = await factory.create(
      `ReClamm Pool`,
      `RECLAMM`,
      buildTokenConfig(poolTokens, withRate),
      roleAccounts,
      fp(0.1), // 10% swap fee percentage
      priceParams,
      fp(1), // 100% price shift daily rate
      fp(0.2), // 20% centeredness margin
      salt
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    const pool = (await deployedAt('ReClammPool', event.args.pool)) as unknown as BaseContract;

    return {
      pool: pool as unknown as BaseContract,
      poolTokens: poolTokens,
    };
  }

  override async itTestsCustomSwaps(poolTag: PoolTag, testDirname: string, poolType: string) {
    let poolInfo: PoolInfo;
    const SWAP_AMOUNT = fp(20);

    sharedBeforeEach(`Save Pool Info (${poolTag})`, async () => {
      poolInfo = this.poolsInfo[poolTag];
    });

    describe(`Update Q0 - In Range (IR) (${poolTag})`, async () => {
      sharedBeforeEach(`Start updating price ratio (${poolTag})`, async () => {
        const [, , swapFeeManager] = await ethers.getSigners();

        const pool: ReClammPool = await deployedAt('ReClammPool', await poolInfo.pool.getAddress());

        const startTimestamp = await currentTimestamp();
        const endTimestamp = startTimestamp + BigInt(DAY * 2);

        await pool.connect(swapFeeManager).startPriceRatioUpdate(
          fp(2), // Price Ratio of 16 (2^4)
          startTimestamp,
          endTimestamp
        );
      });

      it(`measures gas (Router) (${poolTag})`, async () => {
        await advanceTime(HOUR);

        // Warm up.
        let tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - IR - ${poolTag}] swap single token exact in with fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - IR - ${poolTag}] swap single token exact in with fees - warm slots`,
          [receipt]
        );
      });

      it(`measures gas (BatchRouter) (${poolTag})`, async () => {
        // Warm up.
        let tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - IR - ${poolTag} - BatchRouter] swap exact in with one token and fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - IR - ${poolTag} - BatchRouter] swap exact in with one token and fees - warm slots`,
          [receipt]
        );
      });
    });

    describe(`Out of Range (OOR) (${poolTag})`, async () => {
      sharedBeforeEach(`Start updating price interval (${poolTag})`, async () => {
        // Heavily unbalance pool so price interval starts to shift.
        await this.router
          .connect(this.alice)
          .swapSingleTokenExactOut(
            poolInfo.pool,
            poolInfo.poolTokens[1],
            poolInfo.poolTokens[0],
            fp(95),
            MAX_UINT256,
            MAX_UINT256,
            false,
            '0x'
          );
      });

      it(`measures gas (Router) (${poolTag})`, async () => {
        await advanceTime(HOUR);

        // Warm up.
        let tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - OOR - ${poolTag}] swap single token exact in with fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - OOR - ${poolTag}] swap single token exact in with fees - warm slots`,
          [receipt]
        );
      });

      it(`measures gas (BatchRouter) (${poolTag})`, async () => {
        // Warm up.
        let tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - OOR - ${poolTag} - BatchRouter] swap exact in with one token and fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - OOR - ${poolTag} - BatchRouter] swap exact in with one token and fees - warm slots`,
          [receipt]
        );
      });
    });

    describe(`Update Q0 - Out of Range (OOR (${poolTag})`, async () => {
      sharedBeforeEach(`Start updating price interval (${poolTag})`, async () => {
        const [, , swapFeeManager] = await ethers.getSigners();

        const pool: ReClammPool = await deployedAt('ReClammPool', await poolInfo.pool.getAddress());

        const startTimestamp = await currentTimestamp();
        const endTimestamp = startTimestamp + BigInt(DAY * 2);

        await pool.connect(swapFeeManager).startPriceRatioUpdate(
          fp(2), // Price Ratio of 16 (2^4)
          startTimestamp,
          endTimestamp
        );

        // Heavily unbalance pool so price interval starts to shift.
        await this.router
          .connect(this.alice)
          .swapSingleTokenExactOut(
            poolInfo.pool,
            poolInfo.poolTokens[1],
            poolInfo.poolTokens[0],
            fp(95),
            MAX_UINT256,
            MAX_UINT256,
            false,
            '0x'
          );
      });

      it(`measures gas (Router) (${poolTag})`, async () => {
        await advanceTime(HOUR);

        // Warm up.
        let tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - OOR - ${poolTag}] swap single token exact in with fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.router
          .connect(this.alice)
          .swapSingleTokenExactIn(
            poolInfo.pool,
            poolInfo.poolTokens[0],
            poolInfo.poolTokens[1],
            SWAP_AMOUNT,
            0,
            MAX_UINT256,
            false,
            '0x'
          );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - OOR - ${poolTag}] swap single token exact in with fees - warm slots`,
          [receipt]
        );
      });

      it(`measures gas (BatchRouter) (${poolTag})`, async () => {
        // Warm up.
        let tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        let receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - OOR - ${poolTag} - BatchRouter] swap exact in with one token and fees - cold slots`,
          [receipt]
        );

        // Measure gas for the swap.
        tx = await this.batchRouter.connect(this.alice).swapExactIn(
          [
            {
              tokenIn: poolInfo.poolTokens[0],
              steps: [
                {
                  pool: poolInfo.pool,
                  tokenOut: poolInfo.poolTokens[1],
                  isBuffer: false,
                },
              ],
              exactAmountIn: SWAP_AMOUNT,
              minAmountOut: 0,
            },
          ],
          MAX_UINT256,
          false,
          '0x'
        );

        receipt = (await tx.wait())!;

        await saveSnap(
          testDirname,
          `[${poolType} - Update Q0 - OOR - ${poolTag} - BatchRouter] swap exact in with one token and fees - warm slots`,
          [receipt]
        );
      });
    });
  }
}

describe('ReClammPool Gas Benchmark', function () {
  new ReClammBenchmark(__dirname).itBenchmarks();
});
