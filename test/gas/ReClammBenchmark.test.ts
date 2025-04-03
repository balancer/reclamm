/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { ethers } from 'hardhat';
import { deploy, deployedAt } from '@balancer-labs/v3-helpers/src/contract';
import { advanceTime, currentTimestamp, DAY, HOUR, MONTH } from '@balancer-labs/v3-helpers/src/time';
import { buildTokenConfig } from '@balancer-labs/v3-helpers/src/models/tokens/tokenConfig';
import * as expectEvent from '@balancer-labs/v3-helpers/src/test/expectEvent';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';

import {
  Benchmark,
  PoolTag,
  PoolInfo,
  TestsSwapHooks,
  TestCustomSwapsParams,
} from '@balancer-labs/v3-benchmarks/src/PoolBenchmark.behavior';
import { MAX_UINT256, ZERO_ADDRESS, ZERO_BYTES32 } from '@balancer-labs/v3-helpers/src/constants';

import { PoolRoleAccountsStruct } from '../../typechain-types/@balancer-labs/v3-vault/contracts/Vault';
import { ReClammPoolFactory } from '../../typechain-types/contracts/ReClammPoolFactory';
import { ReClammPool } from '../../typechain-types/contracts/ReClammPool';
import { fp } from '@balancer-labs/v3-helpers/src/numbers';
import { saveSnap } from '@balancer-labs/v3-helpers/src/gas';
import { sharedBeforeEach } from '../../lib/balancer-v3-monorepo/pvt/common/sharedBeforeEach';

class ReClammBenchmark extends Benchmark {
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

    const tx = await factory.create(
      'ReClamm Pool',
      'RECLAMM',
      buildTokenConfig(poolTokens, withRate),
      roleAccounts,
      fp(0.1), // 10% swap fee percentage
      fp(1), // 100% price shift daily rate
      fp(2), // price ratio of 16 (2^4)
      fp(0.2), // 20% centeredness margin
      ZERO_BYTES32
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    const pool = (await deployedAt('ReClammPool', event.args.pool)) as unknown as BaseContract;

    return {
      pool: pool as unknown as BaseContract,
      poolTokens: poolTokens,
    };
  }

  override async itTestsCustomSwaps(
    poolTag: PoolTag,
    testDirname: string,
    poolType: string,
    { router, batchRouter, alice, poolInfo }: TestCustomSwapsParams,
    testsHooks?: TestsSwapHooks
  ) {
    const SWAP_AMOUNT = fp(20);

    describe('Updating Price Ratio', async function () {
      sharedBeforeEach(`Start updating price ratio`, async () => {
        const [, , swapFeeManager] = await ethers.getSigners();
        const pool: ReClammPool = await deployedAt('ReClammPool', await poolInfo.pool.getAddress());

        const startTimestamp = await currentTimestamp();
        const endTimestamp = startTimestamp + BigInt(DAY);

        await pool.connect(swapFeeManager).setPriceRatioState(
          fp(3), // Price Ratio of 81 (3^4)
          startTimestamp,
          endTimestamp
        );
      });

      it(`measures gas (Router) (${testsHooks?.gasTag})`, async () => {
        await advanceTime(HOUR);

        const pool: ReClammPool = await deployedAt('ReClammPool', await poolInfo.pool.getAddress());
        // Warm up.
        let tx = await router
          .connect(alice)
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
          `[${poolType} - Updating Q0 - ${testsHooks?.gasTag}] swap single token exact in with fees - cold slots`,
          [receipt]
        );

        if (testsHooks?.actionAfterFirstTx) {
          await testsHooks?.actionAfterFirstTx();
        }

        // Measure gas for the swap.
        tx = await router
          .connect(alice)
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
          `[${poolType} - Updating Q0 - ${testsHooks?.gasTag}] swap single token exact in with fees - warm slots`,
          [receipt]
        );
      });

      it(`measures gas (BatchRouter) (${testsHooks?.gasTag})`, async () => {
        // Warm up.
        let tx = await batchRouter.connect(alice).swapExactIn(
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
          `[${poolType} - Updating Q0 - ${testsHooks?.gasTag} - BatchRouter] swap exact in with one token and fees - cold slots`,
          [receipt]
        );

        if (testsHooks?.actionAfterFirstTx) {
          await testsHooks?.actionAfterFirstTx();
        }

        // Measure gas for the swap.
        tx = await batchRouter.connect(alice).swapExactIn(
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
          `[${poolType} - Updating Q0 - ${testsHooks?.gasTag} - BatchRouter] swap exact in with one token and fees - warm slots`,
          [receipt]
        );
      });
    });
  }
}

describe('ReClammPool Gas Benchmark', function () {
  new ReClammBenchmark(__dirname).itBenchmarks();
});
