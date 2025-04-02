import { ethers } from 'hardhat';
import { expect } from 'chai';
import { deploy, deployedAt } from '@balancer-labs/v3-helpers/src/contract';
import { sharedBeforeEach } from '@balancer-labs/v3-common/sharedBeforeEach';
import { Router } from '@balancer-labs/v3-vault/typechain-types/contracts/Router';
import { ERC20TestToken } from '@balancer-labs/v3-solidity-utils/typechain-types/contracts/test/ERC20TestToken';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { FP_ZERO, bn, fp } from '@balancer-labs/v3-helpers/src/numbers';
import {
  MAX_UINT256,
  MAX_UINT160,
  MAX_UINT48,
  ZERO_BYTES32,
  ZERO_ADDRESS,
} from '@balancer-labs/v3-helpers/src/constants';
import * as VaultDeployer from '@balancer-labs/v3-helpers/src/models/vault/VaultDeployer';
import { IVaultMock } from '@balancer-labs/v3-interfaces/typechain-types';
import TypesConverter from '@balancer-labs/v3-helpers/src/models/types/TypesConverter';
import { buildTokenConfig } from '@balancer-labs/v3-helpers/src/models/tokens/tokenConfig';
import { ReClammPool, ReClammPoolFactory } from '../typechain-types';
import { actionId } from '@balancer-labs/v3-helpers/src/models/misc/actions';
import { advanceTime, currentTimestamp, HOUR, MONTH } from '@balancer-labs/v3-helpers/src/time';
import * as expectEvent from '@balancer-labs/v3-helpers/src/test/expectEvent';
import { sortAddresses } from '@balancer-labs/v3-helpers/src/models/tokens/sortingHelper';
import { deployPermit2 } from '@balancer-labs/v3-vault/test/Permit2Deployer';
import { IPermit2 } from '@balancer-labs/v3-vault/typechain-types/permit2/src/interfaces/IPermit2';
import { PoolConfigStructOutput } from '@balancer-labs/v3-interfaces/typechain-types/contracts/vault/IVault';
import { TokenConfigStruct } from '../typechain-types/@balancer-labs/v3-interfaces/contracts/vault/IVault';
import { getCurrentVirtualBalances, computePriceShiftDailyRate } from './utils/reClammMath';
import { expectEqualWithError } from './utils/relativeError';

describe('ReClammPool', function () {
  const FACTORY_VERSION = 'ReClamm Pool Factory v1';
  const POOL_VERSION = 'ReClamm Pool v1';
  const ROUTER_VERSION = 'Router v11';

  const POOL_SWAP_FEE = fp(0.01);
  const TOKEN_AMOUNT = fp(100);

  const INITIAL_BALANCE_A = TOKEN_AMOUNT;
  const INITIAL_BALANCE_B = 2n * TOKEN_AMOUNT;
  const MIN_POOL_BALANCE = fp(0.0001);

  const SWAP_FEE = fp(0.01); // 1%
  const SQRT_PRICE_RATIO = fp(2); // The ratio between max and min price is 16 (2^4)
  const PRICE_SHIFT_DAILY_RATE = fp(1); // 100%. Price interval can double or reduce by half each day
  // 20%. If pool centeredness is less than margin, price interval will track the market price.
  const CENTEREDNESS_MARGIN = fp(0.2);

  const virtualBalancesError = 0.000000000000001;

  let permit2: IPermit2;
  let vault: IVaultMock;
  let factory: ReClammPoolFactory;
  let pool: ReClammPool;
  let router: Router;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let tokenA: ERC20TestToken;
  let tokenB: ERC20TestToken;
  let poolTokens: string[];

  let tokenAAddress: string;
  let tokenBAddress: string;

  let tokenAIdx: number;
  let tokenBIdx: number;

  let initialBalances: bigint[] = [];

  before('setup signers', async () => {
    [, alice, bob] = await ethers.getSigners();
  });

  sharedBeforeEach('deploy vault, router, tokens, and pool', async function () {
    vault = await TypesConverter.toIVaultMock(await VaultDeployer.deployMock());

    const WETH = await deploy('v3-solidity-utils/WETHTestToken');
    permit2 = await deployPermit2();
    router = await deploy('v3-vault/Router', { args: [vault, WETH, permit2, ROUTER_VERSION] });

    tokenA = await deploy('v3-solidity-utils/ERC20TestToken', { args: ['Token A', 'TKNA', 18] });
    tokenB = await deploy('v3-solidity-utils/ERC20TestToken', { args: ['Token B', 'TKNB', 6] });

    tokenAAddress = await tokenA.getAddress();
    tokenBAddress = await tokenB.getAddress();

    [tokenAIdx, tokenBIdx] = tokenAAddress.localeCompare(tokenBAddress) < 0 ? [0, 1] : [1, 0];

    initialBalances[tokenAIdx] = INITIAL_BALANCE_A;
    initialBalances[tokenBIdx] = INITIAL_BALANCE_B;
  });

  sharedBeforeEach('create and initialize pool', async () => {
    factory = await deploy('ReClammPoolFactory', {
      args: [await vault.getAddress(), MONTH * 12, FACTORY_VERSION, POOL_VERSION],
    });
    poolTokens = sortAddresses([tokenAAddress, tokenBAddress]);

    const tokenConfig: TokenConfigStruct[] = buildTokenConfig(poolTokens);

    const tx = await factory.create(
      'ReClammPool',
      'Test',
      tokenConfig,
      { pauseManager: ZERO_ADDRESS, swapFeeManager: ZERO_ADDRESS, poolCreator: ZERO_ADDRESS },
      SWAP_FEE,
      PRICE_SHIFT_DAILY_RATE,
      SQRT_PRICE_RATIO,
      CENTEREDNESS_MARGIN,
      ZERO_BYTES32
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    pool = (await deployedAt('ReClammPool', event.args.pool)) as unknown as ReClammPool;

    await tokenA.mint(bob, 10n * TOKEN_AMOUNT);
    await tokenB.mint(bob, 10n * TOKEN_AMOUNT);

    await pool.connect(bob).approve(router, MAX_UINT256);
    for (const token of [tokenA, tokenB]) {
      await token.connect(bob).approve(permit2, MAX_UINT256);
      await permit2.connect(bob).approve(token, router, MAX_UINT160, MAX_UINT48);
    }

    await expect(await router.connect(bob).initialize(pool, poolTokens, initialBalances, FP_ZERO, false, '0x'))
      .to.emit(vault, 'PoolInitialized')
      .withArgs(pool);
  });

  sharedBeforeEach('grant permission', async () => {
    const setPoolSwapFeeAction = await actionId(vault, 'setStaticSwapFeePercentage');

    const authorizerAddress = await vault.getAuthorizer();
    const authorizer = await deployedAt('v3-vault/BasicAuthorizerMock', authorizerAddress);

    await authorizer.grantRole(setPoolSwapFeeAction, bob.address);

    await vault.connect(bob).setStaticSwapFeePercentage(pool, POOL_SWAP_FEE);
  });

  it('should have correct versions', async () => {
    expect(await factory.version()).to.eq(FACTORY_VERSION);
    expect(await factory.getPoolVersion()).to.eq(POOL_VERSION);
    expect(await pool.version()).to.eq(POOL_VERSION);
  });

  it('pool and protocol fee preconditions', async () => {
    const poolConfig: PoolConfigStructOutput = await vault.getPoolConfig(pool);

    expect(poolConfig.isPoolRegistered).to.be.true;
    expect(poolConfig.isPoolInitialized).to.be.true;

    expect(await vault.getStaticSwapFeePercentage(pool)).to.eq(POOL_SWAP_FEE);
  });

  it('has the correct pool tokens and balances', async () => {
    const tokensFromPool = await pool.getTokens();
    expect(tokensFromPool).to.deep.equal(poolTokens);

    const [tokensFromVault, , balancesFromVault] = await vault.getPoolTokenInfo(pool);

    expect(tokensFromVault).to.deep.equal(tokensFromPool);
    expect(balancesFromVault).to.deep.equal(initialBalances);
  });

  it('cannot be initialized twice', async () => {
    await expect(router.connect(alice).initialize(pool, poolTokens, initialBalances, FP_ZERO, false, '0x'))
      .to.be.revertedWithCustomError(vault, 'PoolAlreadyInitialized')
      .withArgs(await pool.getAddress());
  });

  it('is registered in the factory', async () => {
    expect(await factory.getPoolCount()).to.be.eq(1);
    expect(await factory.getPools()).to.be.deep.eq([await pool.getAddress()]);
  });

  it('should move virtual balances correctly (out of range > center)', async () => {
    // Very big swap, putting the pool right at the edge.
    const exactAmountOut = INITIAL_BALANCE_B - MIN_POOL_BALANCE - 1n;
    const maxAmountIn = MAX_UINT256;
    const deadline = MAX_UINT256;
    const wethIsEth = false;

    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenA, tokenB, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

    const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);
    const [virtualBalancesAfterSwap] = await pool.getCurrentVirtualBalances();

    const lastTimestamp = await currentTimestamp();
    await advanceTime(HOUR);
    const expectedTimestamp = lastTimestamp + BigInt(HOUR) + 1n;

    // calculate the expected virtual balances in the next swap
    const [expectedFinalVirtualBalances] = getCurrentVirtualBalances(
      poolBalancesAfterSwap,
      virtualBalancesAfterSwap,
      computePriceShiftDailyRate(PRICE_SHIFT_DAILY_RATE),
      lastTimestamp,
      expectedTimestamp,
      CENTEREDNESS_MARGIN,
      {
        startTime: 0,
        endTime: 0,
        startFourthRootPriceRatio: SQRT_PRICE_RATIO,
        endFourthRootPriceRatio: SQRT_PRICE_RATIO,
      }
    );

    expect(expectedFinalVirtualBalances[tokenAIdx]).to.be.greaterThan(virtualBalancesAfterSwap[tokenAIdx]);
    expect(expectedFinalVirtualBalances[tokenBIdx]).to.be.lessThan(virtualBalancesAfterSwap[tokenBIdx]);

    // Swap in the other direction.
    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenB, tokenA, INITIAL_BALANCE_A, MAX_UINT256, deadline, wethIsEth, '0x');

    // Check whether the virtual balances are close to their expected values.
    const [actualFinalVirtualBalances] = await pool.getCurrentVirtualBalances();

    expect(actualFinalVirtualBalances.length).to.be.equal(2);
    expectEqualWithError(actualFinalVirtualBalances[0], expectedFinalVirtualBalances[0], virtualBalancesError);
    expectEqualWithError(actualFinalVirtualBalances[1], expectedFinalVirtualBalances[1], virtualBalancesError);
  });

  it('should move virtual balances correctly (out of range < center)', async () => {
    // Very big swap, putting the pool right at the edge.
    const exactAmountOut = INITIAL_BALANCE_A - MIN_POOL_BALANCE - 1n;
    const maxAmountIn = MAX_UINT256;
    const deadline = MAX_UINT256;
    const wethIsEth = false;

    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenB, tokenA, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

    const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);
    const [virtualBalancesAfterSwap] = await pool.getCurrentVirtualBalances();

    const lastTimestamp = await currentTimestamp();
    await advanceTime(HOUR);
    const expectedTimestamp = lastTimestamp + BigInt(HOUR) + 1n;

    // Calculate the expected virtual balances in the next swap.
    const [expectedFinalVirtualBalances] = getCurrentVirtualBalances(
      poolBalancesAfterSwap,
      virtualBalancesAfterSwap,
      computePriceShiftDailyRate(PRICE_SHIFT_DAILY_RATE),
      lastTimestamp,
      expectedTimestamp,
      CENTEREDNESS_MARGIN,
      {
        startTime: 0,
        endTime: 0,
        startFourthRootPriceRatio: SQRT_PRICE_RATIO,
        endFourthRootPriceRatio: SQRT_PRICE_RATIO,
      }
    );

    expect(expectedFinalVirtualBalances[tokenAIdx]).to.be.lessThan(virtualBalancesAfterSwap[tokenAIdx]);
    expect(expectedFinalVirtualBalances[tokenBIdx]).to.be.greaterThan(virtualBalancesAfterSwap[tokenBIdx]);

    // Swap in the other direction.
    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenA, tokenB, INITIAL_BALANCE_B, MAX_UINT256, deadline, wethIsEth, '0x');

    // Check whether the virtual balances are close to their expected values.
    const [actualFinalVirtualBalances] = await pool.getCurrentVirtualBalances();

    expect(actualFinalVirtualBalances.length).to.be.equal(2);
    expectEqualWithError(actualFinalVirtualBalances[0], expectedFinalVirtualBalances[0], virtualBalancesError);
    expectEqualWithError(actualFinalVirtualBalances[1], expectedFinalVirtualBalances[1], virtualBalancesError);
  });
});
