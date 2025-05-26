import { ethers } from 'hardhat';
import { expect } from 'chai';
import { deploy, deployedAt } from '@balancer-labs/v3-helpers/src/contract';
import { sharedBeforeEach } from '@balancer-labs/v3-common/sharedBeforeEach';
import { Router } from '@balancer-labs/v3-vault/typechain-types/contracts/Router';
import { ERC20TestToken } from '@balancer-labs/v3-solidity-utils/typechain-types/contracts/test/ERC20TestToken';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { FP_ONE, FP_ZERO, bn, fp, fpDivDown, fpMulDown } from '@balancer-labs/v3-helpers/src/numbers';
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
import { advanceTime, currentTimestamp, DAY, HOUR, MONTH } from '@balancer-labs/v3-helpers/src/time';
import * as expectEvent from '@balancer-labs/v3-helpers/src/test/expectEvent';
import { sortAddresses } from '@balancer-labs/v3-helpers/src/models/tokens/sortingHelper';
import { deployPermit2 } from '@balancer-labs/v3-vault/test/Permit2Deployer';
import { IPermit2 } from '@balancer-labs/v3-vault/typechain-types/permit2/src/interfaces/IPermit2';
import { PoolConfigStructOutput } from '@balancer-labs/v3-interfaces/typechain-types/contracts/vault/IVault';
import { TokenConfigStruct } from '../typechain-types/@balancer-labs/v3-interfaces/contracts/vault/IVault';
import {
  computeCurrentVirtualBalances,
  Rounding,
  pureComputeInvariant,
  toDailyPriceShiftBase,
  fourthRoot,
} from './utils/reClammMath';
import { expectEqualWithError } from './utils/relativeError';

describe('ReClammPool', function () {
  const FACTORY_VERSION = 'ReClamm Pool Factory v1';
  const POOL_VERSION = 'ReClamm Pool v1';
  const ROUTER_VERSION = 'Router v11';

  const POOL_SWAP_FEE = fp(0.01);
  const TOKEN_AMOUNT = fp(100);

  const INITIAL_BALANCE_A = TOKEN_AMOUNT;
  const MIN_POOL_BALANCE = fp(0.0001);

  const SWAP_FEE = fp(0.01); // 1%

  const MIN_PRICE = fp(0.5);
  const MAX_PRICE = fp(8);
  const TARGET_PRICE = fp(3);

  // 100%. Price interval can double or reduce by half each day.
  const PRICE_SHIFT_DAILY_RATE = fp(1);
  // 50%. If pool centeredness is less than margin, price interval will track the market price.
  const CENTEREDNESS_MARGIN = fp(0.5);

  const virtualBalancesError = 0.000000000000001;
  const priceRatioError = 0.00001; // 0.001% error tolerance.

  // When comparing a price before and after a swap, the error is small because the prices should not change.
  const pricesSmallError = 0.0001; // 0.01% error tolerance.
  // When comparing a price after time has passed, the error is bigger because we are comparing the actual pool price
  // with an adjustment of the prices before time warp.
  const pricesBigError = 0.02; // 2% error tolerance.
  // If the pool is out of range below center, the price adjustment to compare with the actual price is a division,
  // so the error is a bit bigger.
  const pricesVeryBigError = 0.06; // 6% error tolerance.

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

    tokenA = await deploy('v3-solidity-utils/ERC20TestToken', { args: ['Token A', 'TKN_A', 18] });
    tokenB = await deploy('v3-solidity-utils/ERC20TestToken', { args: ['Token B', 'TKN_B', 6] });

    tokenAAddress = await tokenA.getAddress();
    tokenBAddress = await tokenB.getAddress();

    [tokenAIdx, tokenBIdx] = tokenAAddress.localeCompare(tokenBAddress) < 0 ? [0, 1] : [1, 0];
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
      MIN_PRICE,
      MAX_PRICE,
      TARGET_PRICE,
      PRICE_SHIFT_DAILY_RATE,
      CENTEREDNESS_MARGIN,
      ZERO_BYTES32
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    pool = (await deployedAt('ReClammPool', event.args.pool)) as unknown as ReClammPool;

    // The initial balances must respect the initialization proportion.
    const proportion = await pool.computeInitialBalanceRatio();
    if (tokenAIdx < tokenBIdx) {
      initialBalances[tokenAIdx] = INITIAL_BALANCE_A;
      initialBalances[tokenBIdx] = fpMulDown(INITIAL_BALANCE_A, proportion) / bn(1e12);
    } else {
      initialBalances[tokenAIdx] = INITIAL_BALANCE_A;
      initialBalances[tokenBIdx] = fpDivDown(INITIAL_BALANCE_A, proportion) / bn(1e12);
    }

    await tokenA.mint(bob, 100n * TOKEN_AMOUNT);
    await tokenB.mint(bob, 100n * TOKEN_AMOUNT);

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
    // Permission to set the pool swap fee
    const setPoolSwapFeeAction = await actionId(vault, 'setStaticSwapFeePercentage');

    const authorizerAddress = await vault.getAuthorizer();
    const authorizer = await deployedAt('v3-vault/BasicAuthorizerMock', authorizerAddress);

    await authorizer.grantRole(setPoolSwapFeeAction, bob.address);

    await vault.connect(bob).setStaticSwapFeePercentage(pool, POOL_SWAP_FEE);

    // Permission to set the price ratio
    const setPriceRatioAction = await actionId(pool, 'setPriceRatioState');
    await authorizer.grantRole(setPriceRatioAction, bob.address);
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
    // Very big swap, putting the pool right at the edge. (Token B has 6 decimals, so we need to convert to 18
    // decimals).
    const exactAmountOut = initialBalances[tokenBIdx] - MIN_POOL_BALANCE / bn(1e12) - 1n;
    const maxAmountIn = MAX_UINT256;
    const deadline = MAX_UINT256;
    const wethIsEth = false;

    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenA, tokenB, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

    const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);
    const virtualBalancesAfterSwap = await pool.computeCurrentVirtualBalances();

    const lastTimestamp = await currentTimestamp();
    await advanceTime(HOUR);
    const expectedTimestamp = lastTimestamp + BigInt(HOUR) + 1n;

    const currentFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

    // calculate the expected virtual balances in the next swap
    const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
      poolBalancesAfterSwap,
      [virtualBalancesAfterSwap.currentVirtualBalanceA, virtualBalancesAfterSwap.currentVirtualBalanceB],
      toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
      lastTimestamp,
      expectedTimestamp,
      CENTEREDNESS_MARGIN,
      {
        priceRatioUpdateStartTime: 0,
        priceRatioUpdateEndTime: 0,
        startFourthRootPriceRatio: currentFourthRootPriceRatio,
        endFourthRootPriceRatio: currentFourthRootPriceRatio,
      }
    );

    expect(expectedFinalVirtualBalances[tokenAIdx]).to.be.greaterThan(virtualBalancesAfterSwap.currentVirtualBalanceA);
    expect(expectedFinalVirtualBalances[tokenBIdx]).to.be.lessThan(virtualBalancesAfterSwap.currentVirtualBalanceB);

    // Swap in the other direction.
    await router
      .connect(bob)
      .swapSingleTokenExactOut(pool, tokenB, tokenA, INITIAL_BALANCE_A, MAX_UINT256, deadline, wethIsEth, '0x');

    // Check whether the virtual balances are close to their expected values.
    const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

    expectEqualWithError(
      actualFinalVirtualBalances.currentVirtualBalanceA,
      expectedFinalVirtualBalances[tokenAIdx],
      virtualBalancesError
    );
    expectEqualWithError(
      actualFinalVirtualBalances.currentVirtualBalanceB,
      expectedFinalVirtualBalances[tokenBIdx],
      virtualBalancesError
    );
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
    const virtualBalancesAfterSwap = await pool.computeCurrentVirtualBalances();

    const lastTimestamp = await currentTimestamp();
    await advanceTime(HOUR);
    const expectedTimestamp = lastTimestamp + BigInt(HOUR) + 1n;

    const currentFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

    // Calculate the expected virtual balances in the next swap.
    const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
      poolBalancesAfterSwap,
      [virtualBalancesAfterSwap.currentVirtualBalanceA, virtualBalancesAfterSwap.currentVirtualBalanceB],
      toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
      lastTimestamp,
      expectedTimestamp,
      CENTEREDNESS_MARGIN,
      {
        priceRatioUpdateStartTime: 0,
        priceRatioUpdateEndTime: 0,
        startFourthRootPriceRatio: currentFourthRootPriceRatio,
        endFourthRootPriceRatio: currentFourthRootPriceRatio,
      }
    );

    expect(expectedFinalVirtualBalances[tokenAIdx]).to.be.lessThan(virtualBalancesAfterSwap.currentVirtualBalanceA);
    expect(expectedFinalVirtualBalances[tokenBIdx]).to.be.greaterThan(virtualBalancesAfterSwap.currentVirtualBalanceB);

    // Swap in the other direction.
    await router
      .connect(bob)
      .swapSingleTokenExactOut(
        pool,
        tokenA,
        tokenB,
        initialBalances[tokenBIdx],
        MAX_UINT256,
        deadline,
        wethIsEth,
        '0x'
      );

    // Check whether the virtual balances are close to their expected values.
    const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

    expectEqualWithError(
      actualFinalVirtualBalances.currentVirtualBalanceA,
      expectedFinalVirtualBalances[tokenAIdx],
      virtualBalancesError
    );
    expectEqualWithError(
      actualFinalVirtualBalances.currentVirtualBalanceB,
      expectedFinalVirtualBalances[tokenBIdx],
      virtualBalancesError
    );
  });

  describe('pool out of range and price ratio updating', () => {
    sharedBeforeEach('collect fees', async () => {
      await swapToCollectFeesAndDeconcentrateLiquidity();
    });

    it('should move virtual balances correctly (out of range < center and price ratio concentrating)', async () => {
      const initialFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

      const { minPrice: minPriceBeforeBigSwap, maxPrice: maxPriceBeforeBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        0n,
        0n,
        priceRatioError,
        pricesSmallError,
        false
      );

      // Very big swap, putting the pool right at the edge.
      const [, , poolBalancesBeforeSwapRaw] = await vault.getPoolTokenInfo(pool);
      const exactAmountOut = fpMulDown(poolBalancesBeforeSwapRaw[tokenAIdx], fp(0.99));
      const maxAmountIn = MAX_UINT256;
      const deadline = MAX_UINT256;
      const wethIsEth = false;

      const virtualBalancesBeforeSwap = await pool.computeCurrentVirtualBalances();

      await router
        .connect(bob)
        .swapSingleTokenExactOut(pool, tokenB, tokenA, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

      await checkSpotPriceAfterSwap(virtualBalancesBeforeSwap);

      const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);

      const { minPrice: minPriceAfterBigSwap, maxPrice: maxPriceAfterBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceBeforeBigSwap,
        maxPriceBeforeBigSwap,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // Since price shift daily is 100%, prices will double each day. It's exponential, so we expect that
      // after 6 hours the new prices are oldPrice * 2^(1/4).
      const expectedMinPriceOOR = fpMulDown(minPriceAfterBigSwap, fourthRoot(fp(2)));
      const expectedMaxPriceOOR = fpMulDown(maxPriceAfterBigSwap, fourthRoot(fp(2)));

      // Pool is OOR, so min and max prices moved. However, the price ratio should be the same.
      const { minPrice: minPriceOOR, maxPrice: maxPriceOOR } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        expectedMinPriceOOR,
        expectedMaxPriceOOR,
        priceRatioError,
        pricesBigError,
        true
      );

      // Concentrating liquidity
      // Since the price move introduces some rounding, store the price ratio before the setPriceRatioState call.
      // Notice that "checkPoolPrices" already checked that initialFourthRootPriceRatio matches the current price ratio,
      // so the values are close.
      const startFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();
      const updateStartTimestamp = (await currentTimestamp()) + 1n;
      const updateEndTimestamp = updateStartTimestamp + 1n * BigInt(DAY) + 1n;
      const endFourthRootPriceRatio = fpDivDown(initialFourthRootPriceRatio, fp(1.1));
      await pool.connect(bob).setPriceRatioState(endFourthRootPriceRatio, updateStartTimestamp, updateEndTimestamp);

      // Virtual balances were updated, but prices should not move yet.
      const { minPrice: minPriceAfterSetPriceRatioState } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceOOR,
        maxPriceOOR,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // After 6 hours, there are 2 moves: concentration of liquidity and price shift due to out-of-range state.
      // Since the concentration of liquidity is exponential and the duration is 1 day, it should have moved respecting
      // (final ratio / initial ratio)^1/4.
      const expectedPriceRatioAfterConcentration = fpMulDown(
        initialFourthRootPriceRatio,
        fourthRoot(fpDivDown(endFourthRootPriceRatio, initialFourthRootPriceRatio))
      );
      expectEqualWithError(
        await pool.computeCurrentFourthRootPriceRatio(),
        expectedPriceRatioAfterConcentration,
        priceRatioError
      );

      // The center is equally spaced from min and max price, geometrically, which means that
      // `centerednessPrice / minPrice = maxPrice / centerednessPrice`. Since priceRatio is maxPrice / minPrice,
      // centerednessPrice = sqrt(priceRatio) * minPrice. (or maxPrice / sqrt(priceRatio)).
      const sqrtInitialPriceRatio = fpMulDown(initialFourthRootPriceRatio, initialFourthRootPriceRatio);
      const centerednessPrice = fpMulDown(minPriceAfterSetPriceRatioState, sqrtInitialPriceRatio);
      const sqrtPriceRatioAfterConcentration = fpMulDown(
        expectedPriceRatioAfterConcentration,
        expectedPriceRatioAfterConcentration
      );
      const expectedMinPriceIRAfterConcentration = fpDivDown(centerednessPrice, sqrtPriceRatioAfterConcentration);
      const expectedMaxPriceIRAfterConcentration = fpMulDown(centerednessPrice, sqrtPriceRatioAfterConcentration);

      // Also, the prices are shifting since the pool is OOR. The prices should have moved by the same factor
      // 2ˆ(1/4) = 1.189207, applied to the previous min and max prices.
      const expectedMinPriceOORAfterConcentration = fpMulDown(expectedMinPriceIRAfterConcentration, fp(1.189207));
      const expectedMaxPriceOORAfterConcentration = fpMulDown(expectedMaxPriceIRAfterConcentration, fp(1.189207));
      const { minPrice: minPriceAfterPriceShift, maxPrice: maxPriceAfterPriceShift } = await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        expectedMinPriceOORAfterConcentration,
        expectedMaxPriceOORAfterConcentration,
        priceRatioError,
        pricesBigError,
        true
      );

      const expectedTimestamp = (await currentTimestamp()) + 1n;

      const lastVirtualBalances = await pool.getLastVirtualBalances();

      // Calculate the expected virtual balances in the next swap.
      const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
        poolBalancesAfterSwap,
        lastVirtualBalances,
        toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
        updateStartTimestamp,
        expectedTimestamp,
        CENTEREDNESS_MARGIN,
        {
          priceRatioUpdateStartTime: updateStartTimestamp,
          priceRatioUpdateEndTime: updateEndTimestamp,
          startFourthRootPriceRatio: startFourthRootPriceRatio,
          endFourthRootPriceRatio: endFourthRootPriceRatio,
        }
      );

      const virtualBalancesBeforeFinalSwap = await pool.computeCurrentVirtualBalances();

      // Swap in the other direction.
      await router
        .connect(bob)
        .swapSingleTokenExactOut(
          pool,
          tokenA,
          tokenB,
          initialBalances[tokenBIdx],
          MAX_UINT256,
          deadline,
          wethIsEth,
          '0x'
        );

      // Check whether the virtual balances are close to their expected values.
      const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

      expectEqualWithError(
        actualFinalVirtualBalances[tokenAIdx],
        expectedFinalVirtualBalances[tokenAIdx],
        virtualBalancesError
      );
      expectEqualWithError(
        actualFinalVirtualBalances[tokenBIdx],
        expectedFinalVirtualBalances[tokenBIdx],
        virtualBalancesError
      );

      await checkSpotPriceAfterSwap(virtualBalancesBeforeFinalSwap);

      // Prices should not changed from the last check.
      await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        minPriceAfterPriceShift,
        maxPriceAfterPriceShift,
        priceRatioError,
        pricesSmallError,
        true
      );
    });

    it('should move virtual balances correctly (out of range > center and price ratio concentrating)', async () => {
      const initialFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

      const { minPrice: minPriceBeforeBigSwap, maxPrice: maxPriceBeforeBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        0n,
        0n,
        priceRatioError,
        pricesSmallError,
        false
      );

      // Very big swap, putting the pool right at the edge.
      const [, , poolBalancesBeforeSwapRaw] = await vault.getPoolTokenInfo(pool);
      const exactAmountOut = fpMulDown(poolBalancesBeforeSwapRaw[tokenBIdx], fp(0.9));
      const maxAmountIn = MAX_UINT256;
      const deadline = MAX_UINT256;
      const wethIsEth = false;

      const virtualBalancesBeforeSwap = await pool.computeCurrentVirtualBalances();

      await router
        .connect(bob)
        .swapSingleTokenExactOut(pool, tokenA, tokenB, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

      await checkSpotPriceAfterSwap(virtualBalancesBeforeSwap);

      const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);

      const { minPrice: minPriceAfterBigSwap, maxPrice: maxPriceAfterBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceBeforeBigSwap,
        maxPriceBeforeBigSwap,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // Since price shift daily is 100%, prices will halve each day. It's exponential, so we expect that
      // after 6 hours the new prices are oldPrice / 2^(1/4).
      const expectedMinPriceOOR = fpDivDown(minPriceAfterBigSwap, fourthRoot(fp(2)));
      const expectedMaxPriceOOR = fpDivDown(maxPriceAfterBigSwap, fourthRoot(fp(2)));

      // Pool is OOR, so min and max prices moved. However, the price ratio should be the same.
      const { minPrice: minPriceOOR, maxPrice: maxPriceOOR } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        expectedMinPriceOOR,
        expectedMaxPriceOOR,
        priceRatioError,
        pricesVeryBigError,
        true
      );

      // Concentrating liquidity
      const updateStartTimestamp = (await currentTimestamp()) + 1n;
      const updateEndTimestamp = updateStartTimestamp + 1n * BigInt(DAY) + 1n;
      const endFourthRootPriceRatio = fpDivDown(initialFourthRootPriceRatio, fp(1.1));
      await pool.connect(bob).setPriceRatioState(endFourthRootPriceRatio, updateStartTimestamp, updateEndTimestamp);

      // Virtual balances were updated, but prices should not move yet.
      const { minPrice: minPriceAfterSetPriceRatioState, maxPrice: maxPriceAfterSetPriceRatioState } =
        await checkPoolPrices(
          pool,
          initialFourthRootPriceRatio,
          minPriceOOR,
          maxPriceOOR,
          priceRatioError,
          pricesSmallError,
          true
        );

      await advanceTime(6 * HOUR);

      // After 6 hours, there are 2 moves: concentration of liquidity and price shift due to out-of-range state.
      // Since the concentration of liquidity is exponential and the duration is 1 day, it should have moved respecting
      // (final ratio / initial ratio)^1/4.
      const expectedPriceRatioAfterConcentration = fpMulDown(
        initialFourthRootPriceRatio,
        fourthRoot(fpDivDown(endFourthRootPriceRatio, initialFourthRootPriceRatio))
      );
      expectEqualWithError(
        await pool.computeCurrentFourthRootPriceRatio(),
        expectedPriceRatioAfterConcentration,
        priceRatioError
      );

      // The center is equally spaced from min and max price, geometrically, which means that
      // `centerednessPrice / minPrice = maxPrice / centerednessPrice`. Since priceRatio is maxPrice / minPrice,
      // centerednessPrice = sqrt(priceRatio) * minPrice. (or maxPrice / sqrt(priceRatio)).
      const sqrtInitialPriceRatio = fpMulDown(initialFourthRootPriceRatio, initialFourthRootPriceRatio);
      const centerednessPrice = fpMulDown(minPriceAfterSetPriceRatioState, sqrtInitialPriceRatio);
      const sqrtPriceRatioAfterConcentration = fpMulDown(
        expectedPriceRatioAfterConcentration,
        expectedPriceRatioAfterConcentration
      );
      const expectedMinPriceIRAfterConcentration = fpDivDown(centerednessPrice, sqrtPriceRatioAfterConcentration);
      const expectedMaxPriceIRAfterConcentration = fpMulDown(centerednessPrice, sqrtPriceRatioAfterConcentration);

      // Also, the prices are shifting since the pool is OOR. The prices should have moved by the same factor
      // 2ˆ(1/4), applied to the previous min and max prices.
      const expectedMinPriceOORAfterConcentration = fpDivDown(expectedMinPriceIRAfterConcentration, fourthRoot(fp(2)));
      const expectedMaxPriceOORAfterConcentration = fpDivDown(expectedMaxPriceIRAfterConcentration, fourthRoot(fp(2)));
      const { minPrice: minPriceAfterPriceShift, maxPrice: maxPriceAfterPriceShift } = await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        expectedMinPriceOORAfterConcentration,
        expectedMaxPriceOORAfterConcentration,
        priceRatioError,
        pricesVeryBigError,
        true
      );

      const expectedTimestamp = (await currentTimestamp()) + 1n;

      const lastVirtualBalances = await pool.getLastVirtualBalances();

      // Calculate the expected virtual balances in the next swap.
      const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
        poolBalancesAfterSwap,
        lastVirtualBalances,
        toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
        updateStartTimestamp,
        expectedTimestamp,
        CENTEREDNESS_MARGIN,
        {
          priceRatioUpdateStartTime: updateStartTimestamp,
          priceRatioUpdateEndTime: updateEndTimestamp,
          startFourthRootPriceRatio: initialFourthRootPriceRatio,
          endFourthRootPriceRatio: endFourthRootPriceRatio,
        }
      );

      const virtualBalancesBeforeFinalSwap = await pool.computeCurrentVirtualBalances();

      // Swap in the other direction.
      await router
        .connect(bob)
        .swapSingleTokenExactIn(pool, tokenB, tokenA, exactAmountOut, 0, deadline, wethIsEth, '0x');

      // Check whether the virtual balances are close to their expected values.
      const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

      expectEqualWithError(
        actualFinalVirtualBalances[tokenAIdx],
        expectedFinalVirtualBalances[tokenAIdx],
        virtualBalancesError
      );
      expectEqualWithError(
        actualFinalVirtualBalances[tokenBIdx],
        expectedFinalVirtualBalances[tokenBIdx],
        virtualBalancesError
      );

      await checkSpotPriceAfterSwap(virtualBalancesBeforeFinalSwap);

      // Prices should not changed from the last check.
      await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        minPriceAfterPriceShift,
        maxPriceAfterPriceShift,
        priceRatioError,
        pricesSmallError,
        true
      );
    });

    it('should move virtual balances correctly (out of range < center and price ratio deconcentrating)', async () => {
      const initialFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

      const { minPrice: minPriceBeforeBigSwap, maxPrice: maxPriceBeforeBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        0n,
        0n,
        priceRatioError,
        pricesSmallError,
        false
      );

      // Very big swap, putting the pool right at the edge.
      const [, , poolBalancesBeforeSwapRaw] = await vault.getPoolTokenInfo(pool);
      const exactAmountOut = fpMulDown(poolBalancesBeforeSwapRaw[tokenAIdx], fp(0.99));
      const maxAmountIn = MAX_UINT256;
      const deadline = MAX_UINT256;
      const wethIsEth = false;

      const virtualBalancesBeforeSwap = await pool.computeCurrentVirtualBalances();

      await router
        .connect(bob)
        .swapSingleTokenExactOut(pool, tokenB, tokenA, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

      await checkSpotPriceAfterSwap(virtualBalancesBeforeSwap);

      const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);

      const { minPrice: minPriceAfterBigSwap, maxPrice: maxPriceAfterBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceBeforeBigSwap,
        maxPriceBeforeBigSwap,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // Since price shift daily is 100%, prices will double each day. It's exponential, so we expect that
      // after 6 hours the new prices are oldPrice * 2^(1/4).
      const expectedMinPriceOOR = fpMulDown(minPriceAfterBigSwap, fourthRoot(fp(2)));
      const expectedMaxPriceOOR = fpMulDown(maxPriceAfterBigSwap, fourthRoot(fp(2)));

      // Pool is OOR, so min and max prices moved. However, the price ratio should be the same.
      const { minPrice: minPriceOOR, maxPrice: maxPriceOOR } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        expectedMinPriceOOR,
        expectedMaxPriceOOR,
        priceRatioError,
        pricesBigError,
        true
      );

      // Deconcentrating liquidity
      // Since the price move introduces some rounding, store the price ratio before the setPriceRatioState call.
      // Notice that "checkPoolPrices" already checked that initialFourthRootPriceRatio matches the current price ratio,
      // so the values are close.
      const startFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();
      const updateStartTimestamp = (await currentTimestamp()) + 1n;
      const updateEndTimestamp = updateStartTimestamp + 1n * BigInt(DAY) + 1n;
      const endFourthRootPriceRatio = fpMulDown(initialFourthRootPriceRatio, fp(1.1));
      await pool.connect(bob).setPriceRatioState(endFourthRootPriceRatio, updateStartTimestamp, updateEndTimestamp);

      // Virtual balances were updated, but prices should not move yet.
      const { minPrice: minPriceAfterSetPriceRatioState } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceOOR,
        maxPriceOOR,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // After 6 hours, there are 2 moves: concentration of liquidity and price shift due to out-of-range state.
      // Since the concentration of liquidity is exponential and the duration is 1 day, it should have moved respecting
      // (final ratio / initial ratio)^1/4.
      const expectedPriceRatioAfterConcentration = fpMulDown(
        initialFourthRootPriceRatio,
        fourthRoot(fpDivDown(endFourthRootPriceRatio, initialFourthRootPriceRatio))
      );
      expectEqualWithError(
        await pool.computeCurrentFourthRootPriceRatio(),
        expectedPriceRatioAfterConcentration,
        priceRatioError
      );

      // The center is equally spaced from min and max price, geometrically, which means that
      // `centerednessPrice / minPrice = maxPrice / centerednessPrice`. Since priceRatio is maxPrice / minPrice,
      // centerednessPrice = sqrt(priceRatio) * minPrice. (or maxPrice / sqrt(priceRatio)).
      const sqrtInitialPriceRatio = fpMulDown(initialFourthRootPriceRatio, initialFourthRootPriceRatio);
      const centerednessPrice = fpMulDown(minPriceAfterSetPriceRatioState, sqrtInitialPriceRatio);
      const sqrtPriceRatioAfterConcentration = fpMulDown(
        expectedPriceRatioAfterConcentration,
        expectedPriceRatioAfterConcentration
      );
      const expectedMinPriceIRAfterConcentration = fpDivDown(centerednessPrice, sqrtPriceRatioAfterConcentration);
      const expectedMaxPriceIRAfterConcentration = fpMulDown(centerednessPrice, sqrtPriceRatioAfterConcentration);

      // Also, the prices are shifting since the pool is OOR. The prices should have moved by the same factor
      // 2ˆ(1/4) = 1.189207, applied to the previous min and max prices.
      const expectedMinPriceOORAfterConcentration = fpMulDown(expectedMinPriceIRAfterConcentration, fp(1.189207));
      const expectedMaxPriceOORAfterConcentration = fpMulDown(expectedMaxPriceIRAfterConcentration, fp(1.189207));
      const { minPrice: minPriceAfterPriceShift, maxPrice: maxPriceAfterPriceShift } = await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        expectedMinPriceOORAfterConcentration,
        expectedMaxPriceOORAfterConcentration,
        priceRatioError,
        pricesBigError,
        true
      );

      const expectedTimestamp = (await currentTimestamp()) + 1n;

      const lastVirtualBalances = await pool.getLastVirtualBalances();

      // Calculate the expected virtual balances in the next swap.
      const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
        poolBalancesAfterSwap,
        lastVirtualBalances,
        toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
        updateStartTimestamp,
        expectedTimestamp,
        CENTEREDNESS_MARGIN,
        {
          priceRatioUpdateStartTime: updateStartTimestamp,
          priceRatioUpdateEndTime: updateEndTimestamp,
          startFourthRootPriceRatio: startFourthRootPriceRatio,
          endFourthRootPriceRatio: endFourthRootPriceRatio,
        }
      );

      const virtualBalancesBeforeFinalSwap = await pool.computeCurrentVirtualBalances();

      // Swap in the other direction.
      await router
        .connect(bob)
        .swapSingleTokenExactOut(
          pool,
          tokenA,
          tokenB,
          initialBalances[tokenBIdx],
          MAX_UINT256,
          deadline,
          wethIsEth,
          '0x'
        );

      // Check whether the virtual balances are close to their expected values.
      const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

      expectEqualWithError(
        actualFinalVirtualBalances[tokenAIdx],
        expectedFinalVirtualBalances[tokenAIdx],
        virtualBalancesError
      );
      expectEqualWithError(
        actualFinalVirtualBalances[tokenBIdx],
        expectedFinalVirtualBalances[tokenBIdx],
        virtualBalancesError
      );

      await checkSpotPriceAfterSwap(virtualBalancesBeforeFinalSwap);

      // Prices should not changed from the last check.
      await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        minPriceAfterPriceShift,
        maxPriceAfterPriceShift,
        priceRatioError,
        pricesSmallError,
        true
      );
    });

    it('should move virtual balances correctly (out of range > center and price ratio deconcentrating)', async () => {
      const initialFourthRootPriceRatio = await pool.computeCurrentFourthRootPriceRatio();

      const { minPrice: minPriceBeforeBigSwap, maxPrice: maxPriceBeforeBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        0n,
        0n,
        priceRatioError,
        pricesSmallError,
        false
      );

      // Very big swap, putting the pool right at the edge.
      const [, , poolBalancesBeforeSwapRaw] = await vault.getPoolTokenInfo(pool);
      const exactAmountOut = fpMulDown(poolBalancesBeforeSwapRaw[tokenBIdx], fp(0.9));
      const maxAmountIn = MAX_UINT256;
      const deadline = MAX_UINT256;
      const wethIsEth = false;

      const virtualBalancesBeforeSwap = await pool.computeCurrentVirtualBalances();

      await router
        .connect(bob)
        .swapSingleTokenExactOut(pool, tokenA, tokenB, exactAmountOut, maxAmountIn, deadline, wethIsEth, '0x');

      await checkSpotPriceAfterSwap(virtualBalancesBeforeSwap);

      const [, , , poolBalancesAfterSwap] = await vault.getPoolTokenInfo(pool);

      const { minPrice: minPriceAfterBigSwap, maxPrice: maxPriceAfterBigSwap } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        minPriceBeforeBigSwap,
        maxPriceBeforeBigSwap,
        priceRatioError,
        pricesSmallError,
        true
      );

      await advanceTime(6 * HOUR);

      // Since price shift daily is 100%, prices will halve each day. It's exponential, so we expect that
      // after 6 hours the new prices are oldPrice / 2^(1/4).
      const expectedMinPriceOOR = fpDivDown(minPriceAfterBigSwap, fourthRoot(fp(2)));
      const expectedMaxPriceOOR = fpDivDown(maxPriceAfterBigSwap, fourthRoot(fp(2)));

      // Pool is OOR, so min and max prices moved. However, the price ratio should be the same.
      const { minPrice: minPriceOOR, maxPrice: maxPriceOOR } = await checkPoolPrices(
        pool,
        initialFourthRootPriceRatio,
        expectedMinPriceOOR,
        expectedMaxPriceOOR,
        priceRatioError,
        pricesVeryBigError,
        true
      );

      // Deconcentrating liquidity
      const updateStartTimestamp = (await currentTimestamp()) + 1n;
      const updateEndTimestamp = updateStartTimestamp + 1n * BigInt(DAY) + 1n;
      const endFourthRootPriceRatio = fpMulDown(initialFourthRootPriceRatio, fp(1.1));
      await pool.connect(bob).setPriceRatioState(endFourthRootPriceRatio, updateStartTimestamp, updateEndTimestamp);

      // Virtual balances were updated, but prices should not move yet.
      const { minPrice: minPriceAfterSetPriceRatioState, maxPrice: maxPriceAfterSetPriceRatioState } =
        await checkPoolPrices(
          pool,
          initialFourthRootPriceRatio,
          minPriceOOR,
          maxPriceOOR,
          priceRatioError,
          pricesSmallError,
          true
        );

      await advanceTime(6 * HOUR);

      // After 6 hours, there are 2 moves: concentration of liquidity and price shift due to out-of-range state.
      // Since the concentration of liquidity is exponential and the duration is 1 day, it should have moved respecting
      // (final ratio / initial ratio)^1/4.
      const expectedPriceRatioAfterConcentration = fpMulDown(
        initialFourthRootPriceRatio,
        fourthRoot(fpDivDown(endFourthRootPriceRatio, initialFourthRootPriceRatio))
      );
      expectEqualWithError(
        await pool.computeCurrentFourthRootPriceRatio(),
        expectedPriceRatioAfterConcentration,
        priceRatioError
      );

      // The center is equally spaced from min and max price, geometrically, which means that
      // `centerednessPrice / minPrice = maxPrice / centerednessPrice`. Since priceRatio is maxPrice / minPrice,
      // centerednessPrice = sqrt(priceRatio) * minPrice. (or maxPrice / sqrt(priceRatio)).
      const sqrtInitialPriceRatio = fpMulDown(initialFourthRootPriceRatio, initialFourthRootPriceRatio);
      const centerednessPrice = fpMulDown(minPriceAfterSetPriceRatioState, sqrtInitialPriceRatio);
      const sqrtPriceRatioAfterConcentration = fpMulDown(
        expectedPriceRatioAfterConcentration,
        expectedPriceRatioAfterConcentration
      );
      const expectedMinPriceIRAfterConcentration = fpDivDown(centerednessPrice, sqrtPriceRatioAfterConcentration);
      const expectedMaxPriceIRAfterConcentration = fpMulDown(centerednessPrice, sqrtPriceRatioAfterConcentration);

      // Also, the prices are shifting since the pool is OOR. The prices should have moved by the same factor
      // 2ˆ(1/4), applied to the previous min and max prices.
      const expectedMinPriceOORAfterConcentration = fpDivDown(expectedMinPriceIRAfterConcentration, fourthRoot(fp(2)));
      const expectedMaxPriceOORAfterConcentration = fpDivDown(expectedMaxPriceIRAfterConcentration, fourthRoot(fp(2)));
      const { minPrice: minPriceAfterPriceShift, maxPrice: maxPriceAfterPriceShift } = await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        expectedMinPriceOORAfterConcentration,
        expectedMaxPriceOORAfterConcentration,
        priceRatioError,
        pricesVeryBigError,
        true
      );

      const expectedTimestamp = (await currentTimestamp()) + 1n;

      const lastVirtualBalances = await pool.getLastVirtualBalances();

      // Calculate the expected virtual balances in the next swap.
      const [expectedFinalVirtualBalances] = computeCurrentVirtualBalances(
        poolBalancesAfterSwap,
        lastVirtualBalances,
        toDailyPriceShiftBase(PRICE_SHIFT_DAILY_RATE),
        updateStartTimestamp,
        expectedTimestamp,
        CENTEREDNESS_MARGIN,
        {
          priceRatioUpdateStartTime: updateStartTimestamp,
          priceRatioUpdateEndTime: updateEndTimestamp,
          startFourthRootPriceRatio: initialFourthRootPriceRatio,
          endFourthRootPriceRatio: endFourthRootPriceRatio,
        }
      );

      const virtualBalancesBeforeFinalSwap = await pool.computeCurrentVirtualBalances();

      // Swap in the other direction.
      await router
        .connect(bob)
        .swapSingleTokenExactIn(pool, tokenB, tokenA, exactAmountOut, 0, deadline, wethIsEth, '0x');

      // Check whether the virtual balances are close to their expected values.
      const actualFinalVirtualBalances = await pool.computeCurrentVirtualBalances();

      expectEqualWithError(
        actualFinalVirtualBalances[tokenAIdx],
        expectedFinalVirtualBalances[tokenAIdx],
        virtualBalancesError
      );
      expectEqualWithError(
        actualFinalVirtualBalances[tokenBIdx],
        expectedFinalVirtualBalances[tokenBIdx],
        virtualBalancesError
      );

      await checkSpotPriceAfterSwap(virtualBalancesBeforeFinalSwap);

      // Prices should not changed from the last check.
      await checkPoolPrices(
        pool,
        expectedPriceRatioAfterConcentration,
        minPriceAfterPriceShift,
        maxPriceAfterPriceShift,
        priceRatioError,
        pricesSmallError,
        true
      );
    });
  });

  async function swapToCollectFeesAndDeconcentrateLiquidity(): Promise<bigint> {
    // 10% swap fee, will accumulate in the pool.
    await vault.connect(bob).setStaticSwapFeePercentage(pool, fp(0.1));

    // check price ratio before
    const fourthRootPriceRatioBeforeSwaps = await pool.computeCurrentFourthRootPriceRatio();

    // Do a lot of swaps with 80% of pool liquidity to collect fees. This will move the price ratio up,
    // deconcentrating the liquidity.
    for (let i = 0; i < 50; i++) {
      await router
        .connect(bob)
        .swapSingleTokenExactIn(
          pool,
          tokenA,
          tokenB,
          fpMulDown(INITIAL_BALANCE_A, fp(0.8)),
          0,
          MAX_UINT256,
          false,
          '0x'
        );
      await router
        .connect(bob)
        .swapSingleTokenExactOut(
          pool,
          tokenB,
          tokenA,
          fpMulDown(INITIAL_BALANCE_A, fp(0.9 * 0.8)),
          MAX_UINT256,
          MAX_UINT256,
          false,
          '0x'
        );
    }

    // 0% swap fee, making sure no fees will be accrued by the pool in the next swaps.
    await vault.connect(bob).manualUnsafeSetStaticSwapFeePercentage(pool, fp(0));

    const fourthRootPriceRatioAfterSwaps = await pool.computeCurrentFourthRootPriceRatio();
    // Make sure the fourth root price ratio increased by 2x (it means, price ratio increased by 16 times), at least.
    expect(fourthRootPriceRatioAfterSwaps).to.be.greaterThan(2n * fourthRootPriceRatioBeforeSwaps);

    return fourthRootPriceRatioAfterSwaps;
  }

  async function checkPoolPrices(
    pool: ReClammPool,
    currentFourthRootPriceRatio: bigint,
    expectedMinPrice: bigint,
    expectedMaxPrice: bigint,
    expectedPriceRatioError: number,
    expectedPricesError: number,
    compareMinAndMaxPrices: boolean
  ): Promise<{ minPrice: bigint; maxPrice: bigint }> {
    const [virtualBalanceA, virtualBalanceB] = await pool.computeCurrentVirtualBalances();

    const virtualBalances = [virtualBalanceA, virtualBalanceB];
    const [, , , poolBalances] = await vault.getPoolTokenInfo(pool);

    const invariant = pureComputeInvariant(poolBalances, virtualBalances, Rounding.ROUND_DOWN);

    const minPrice = (virtualBalances[tokenBIdx] * virtualBalances[tokenBIdx]) / invariant;
    const maxPrice = fpDivDown(invariant, fpMulDown(virtualBalances[tokenAIdx], virtualBalances[tokenAIdx]));

    const sqrtPriceRatio = fpMulDown(currentFourthRootPriceRatio, currentFourthRootPriceRatio);
    const priceRatio = fpMulDown(sqrtPriceRatio, sqrtPriceRatio);

    expectEqualWithError(fpDivDown(maxPrice, minPrice), priceRatio, expectedPriceRatioError);
    if (compareMinAndMaxPrices) {
      expectEqualWithError(minPrice, expectedMinPrice, expectedPricesError);
      expectEqualWithError(maxPrice, expectedMaxPrice, expectedPricesError);
    }

    return { minPrice, maxPrice };
  }

  async function checkSpotPriceAfterSwap(virtualBalancesBeforeSwap: bigint[]) {
    const [, , poolBalancesAfterSwapRaw] = await vault.getPoolTokenInfo(pool);

    // Warps 1 second, so the current timestamp won't match the last timestamp and the current virtual balances will
    // be recomputed.
    await advanceTime(1n);
    const virtualBalancesWithPoolOnEdge = await pool.computeCurrentVirtualBalances();

    // During a swap, the invariant should be constant. It means, the swap itself only changes the real balances and
    // do not affect the virtual ones. What affect the virtual balances is the time passing if the pool is
    // out-of-range or with price ratio updating. Therefore, if we compute the virtual balances before the swap, or
    // after the swap but in the same timestamp, the virtual balances should be the same.
    const spotPriceAfterSwap = computeSpotPrice(poolBalancesAfterSwapRaw, virtualBalancesBeforeSwap);
    // After 1 second, if the pool is out-of-range or updating price ratio, the virtual balances should have changed,
    // but respecting the price shift daily rate. It means, even though the virtual balances are different, the spot
    // price is still very close.
    const spotPriceAfterSwapAndTimeWarp = computeSpotPrice(poolBalancesAfterSwapRaw, virtualBalancesWithPoolOnEdge);

    // If the spot price is not very close from the one right after the swap, it means that the virtual balances
    // changed abruptly.
    expectEqualWithError(spotPriceAfterSwap, spotPriceAfterSwapAndTimeWarp, pricesSmallError);
  }

  function computeSpotPrice(poolBalances: bigint[], virtualBalances: bigint[]): bigint {
    return fpMulDown(
      poolBalances[tokenBIdx] + virtualBalances[tokenBIdx],
      poolBalances[tokenAIdx] + virtualBalances[tokenAIdx]
    );
  }
});
