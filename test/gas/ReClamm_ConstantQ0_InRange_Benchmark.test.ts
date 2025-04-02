/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { deploy, deployedAt } from '@balancer-labs/v3-helpers/src/contract';
import { MONTH } from '@balancer-labs/v3-helpers/src/time';
import { buildTokenConfig } from '@balancer-labs/v3-helpers/src/models/tokens/tokenConfig';
import * as expectEvent from '@balancer-labs/v3-helpers/src/test/expectEvent';

import { Benchmark, PoolTag, PoolInfo } from '@balancer-labs/v3-benchmarks/src/PoolBenchmark.behavior';
import { ZERO_ADDRESS, ZERO_BYTES32 } from '@balancer-labs/v3-helpers/src/constants';

import { PoolRoleAccountsStruct } from '../../typechain-types/@balancer-labs/v3-vault/contracts/Vault';
import { ReClammPoolFactory } from '../../typechain-types/contracts/ReClammPoolFactory';
import { fp } from '@balancer-labs/v3-helpers/src/numbers';

class ReClammConstantQ0InRangeBenchmark extends Benchmark {
  constructor(dirname: string) {
    super(dirname, 'ReClamm - Constant Q0 - In Range', {
      offNestedPoolTests: true,
      offDonationTests: true,
      offUnbalancedLiquidityTests: true,
    });
  }

  override async deployPool(tag: PoolTag, poolTokens: string[], withRate: boolean): Promise<PoolInfo> {
    const factory = (await deploy('ReClammPoolFactory', {
      args: [await this.vault.getAddress(), MONTH * 12, 'Factory v1', 'Pool v1'],
    })) as unknown as ReClammPoolFactory;

    const roleAccounts: PoolRoleAccountsStruct = {
      poolCreator: ZERO_ADDRESS,
      pauseManager: ZERO_ADDRESS,
      swapFeeManager: ZERO_ADDRESS,
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
}

describe('ReClammPool Gas Benchmark', function () {
  new ReClammConstantQ0InRangeBenchmark(__dirname).itBenchmarks();
});
