import { Contract } from 'ethers';
import { deploy } from '@balancer-labs/v3-helpers/src/contract';
import { ethers } from 'hardhat';

import { expect } from 'chai';
import { bn, fp } from '@balancer-labs/v3-helpers/src/numbers';
import {
  calculateCenteredness,
  calculateInGivenOut,
  calculateOutGivenIn,
  calculateFourthRootPriceRatio,
  computeInvariant,
  getCurrentVirtualBalances,
  isAboveCenter,
  isPoolInRange,
  computePriceShiftDailyRate,
  pureComputeInvariant,
  Rounding,
  PriceRatioState,
  computeTheoreticalPriceRatioAndBalances,
} from './utils/reClammMath';
import { expectEqualWithError } from './utils/relativeError';

const TIME_CONSTANT = fp(1) / 124000n;
const CENTEREDNESS_MARGIN = fp(0.2);
const BALANCES_IN_RANGE = [fp(1), fp(1)];
const BALANCES_OUT_OF_RANGE = [fp(1), bn(1e15)];
const INITIAL_VIRTUAL_BALANCES = [fp(1), fp(1)];

const getTimestampFromLastBlock = async (): Promise<number> => {
  const blockNumBefore = await ethers.provider.getBlockNumber();
  const blockBefore = await ethers.provider.getBlock(blockNumBefore);
  return blockBefore.timestamp;
};

const getPriceRatioState = async (endTimeOffset = 0): Promise<PriceRatioState> => {
  const currentTimestamp = await getTimestampFromLastBlock();
  return {
    priceRatioUpdateStartTime: currentTimestamp - 1000,
    priceRatioUpdateEndTime: currentTimestamp - 500 + endTimeOffset,
    startFourthRootPriceRatio: bn(1.5e18),
    endFourthRootPriceRatio: bn(2e18),
  };
};

describe('ReClammMath', function () {
  const EXPECTED_RELATIVE_ERROR = 1e-12;

  let mathLib: Contract;

  before(async function () {
    mathLib = await deploy('ReClammMathMock');
  });

  context('computePriceShiftDailyRate', () => {
    it('should return the correct value', async () => {
      const priceShiftDailyRate = bn(1000e18);
      const contractResult = await mathLib.computePriceShiftDailyRate(priceShiftDailyRate);

      expect(contractResult).to.equal(computePriceShiftDailyRate(priceShiftDailyRate));
    });
  });

  context('isAboveCenter', () => {
    it('balancesScaled18[1] == 0', async () => {
      const balances = [bn(300e18), bn(0)];
      const virtualBalances = [bn(100e18), bn(200e18)];
      const res = await mathLib.isAboveCenter(balances, virtualBalances);
      expect(res).to.equal(isAboveCenter(balances, virtualBalances));
      expect(res).to.equal(true);
    });

    it('balancesScaled18[1] != 0 && balanceA/BalanceB > vBalanaceA/vBalanceB', async () => {
      const balances = [bn(300e18), bn(0)];
      const virtualBalances = [bn(100e18), bn(200e18)];
      const res = await mathLib.isAboveCenter(balances, virtualBalances);
      expect(await mathLib.isAboveCenter(balances, virtualBalances)).to.equal(isAboveCenter(balances, virtualBalances));
      expect(res).to.equal(true);
    });

    it('balancesScaled18[1] != 0 && balanceA/BalanceB < vBalanaceA/vBalanceB', async () => {
      const balances = [bn(100e18), bn(100e18)];
      const virtualBalances = [bn(110e18), bn(100e18)];
      const res = await mathLib.isAboveCenter(balances, virtualBalances);
      expect(await mathLib.isAboveCenter(balances, virtualBalances)).to.equal(isAboveCenter(balances, virtualBalances));
      expect(res).to.equal(false);
    });
  });

  context('calculateCenteredness', () => {
    it('balancesScaled18[0] == 0', async () => {
      const balances = [bn(0), bn(100e18)];
      const virtualBalances = [bn(100e18), bn(100e18)];

      const res = await mathLib.calculateCenteredness(balances, virtualBalances);
      expect(res).to.equal(await calculateCenteredness(balances, virtualBalances));
      expect(res).to.equal(0n);
    });

    it('balancesScaled18[1] == 0', async () => {
      const balances = [bn(100e18), bn(0)];
      const virtualBalances = [bn(100e18), bn(100e18)];

      const res = await mathLib.calculateCenteredness(balances, virtualBalances);
      expect(res).to.equal(await calculateCenteredness(balances, virtualBalances));
      expect(res).to.equal(0n);
    });

    it('balancesScaled18[1] != 0 && isAboveCenter', async () => {
      const balances = [bn(100e18), bn(100e18)];
      const virtualBalances = [bn(90e18), bn(100e18)];

      const res = await mathLib.calculateCenteredness(balances, virtualBalances);
      expect(res).to.equal(await calculateCenteredness(balances, virtualBalances));
      expect(res).to.not.equal(0n);
    });

    it('balancesScaled18[1] != 0 && isAboveCenter == false', async () => {
      const balances = [bn(100e18), bn(100e18)];
      const virtualBalances = [bn(110e18), bn(100e18)];

      const res = await mathLib.calculateCenteredness(balances, virtualBalances);
      expect(res).to.equal(await calculateCenteredness(balances, virtualBalances));
      expect(res).to.not.equal(0n);
    });
  });

  context('isPoolInRange', () => {
    it('centeredness >= centerednessMargin', async () => {
      const balances = [bn(100e18), bn(100e18)];
      const virtualBalances = [bn(90e18), bn(100e18)];

      const res = await mathLib.isPoolInRange(balances, virtualBalances, CENTEREDNESS_MARGIN);
      expect(res).to.equal(isPoolInRange(balances, virtualBalances, CENTEREDNESS_MARGIN));
      expect(res).to.equal(true);
    });

    it('centeredness < centerednessMargin', async () => {
      const balances = [bn(100e18), bn(1e14)];
      const virtualBalances = [bn(100e18), bn(100e18)];

      const res = await mathLib.isPoolInRange(balances, virtualBalances, CENTEREDNESS_MARGIN);
      expect(res).to.equal(isPoolInRange(balances, virtualBalances, CENTEREDNESS_MARGIN));
      expect(res).to.equal(false);
    });
  });

  context('computeTheoreticalPriceRatioAndBalances', () => {
    it('should return the correct value', async () => {
      const minPrice = fp(1000);
      const maxPrice = fp(4000);
      const targetPrice = fp(2500);

      const [theoreticalBalancesSol, virtualBalancesSol, fourthRootPriceRatioSol] =
        await mathLib.computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);
      const {
        realBalances: theoreticalBalancesJs,
        virtualBalances: virtualBalancesJs,
        fourthRootPriceRatio: fourthRootPriceRatioJs,
      } = computeTheoreticalPriceRatioAndBalances(minPrice, maxPrice, targetPrice);

      // Error of 0.0001%, because the sqrt libraries behave a bit differently
      expectEqualWithError(theoreticalBalancesSol[0], theoreticalBalancesJs[0], 0.000001);
      expectEqualWithError(theoreticalBalancesSol[1], theoreticalBalancesJs[1], 0.000001);
      expectEqualWithError(virtualBalancesSol[0], virtualBalancesJs[0], 0.000001);
      expectEqualWithError(virtualBalancesSol[1], virtualBalancesJs[1], 0.000001);
      expectEqualWithError(fourthRootPriceRatioSol, fourthRootPriceRatioJs, 0.000001);
    });
  });

  context('calculateInGivenOut', () => {
    it('should return the correct value', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const virtualBalances = [bn(100e18), bn(100e18)];
      const tokenInIndex = 0;
      const tokenOutIndex = 1;
      const amountGivenScaled18 = bn(10e18);

      const res = await mathLib.calculateInGivenOut(
        balancesScaled18,
        virtualBalances,
        tokenInIndex,
        tokenOutIndex,
        amountGivenScaled18
      );
      expect(res).to.equal(
        calculateInGivenOut(balancesScaled18, virtualBalances, tokenInIndex, tokenOutIndex, amountGivenScaled18)
      );
    });
  });

  context('calculateOutGivenIn', () => {
    it('should return the correct value', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const virtualBalances = [bn(100e18), bn(100e18)];
      const tokenInIndex = 0;
      const tokenOutIndex = 1;
      const amountGivenScaled18 = bn(10e18);

      const res = await mathLib.calculateOutGivenIn(
        balancesScaled18,
        virtualBalances,
        tokenInIndex,
        tokenOutIndex,
        amountGivenScaled18
      );
      expect(res).to.equal(
        calculateOutGivenIn(balancesScaled18, virtualBalances, tokenInIndex, tokenOutIndex, amountGivenScaled18)
      );
    });
  });

  context('calculateFourthRootPriceRatio', () => {
    it('should return endFourthRootPriceRatioFp when currentTime > endTime', async () => {
      const currentTime = 100;
      const startFourthRootPriceRatioFp = bn(100e18);
      const endFourthRootPriceRatioFp = bn(300e18);
      const priceRatioUpdateStartTime = 1;
      const priceRatioUpdateEndTime = 50;

      const contractResult = await mathLib.calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );
      const mathResult = calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(endFourthRootPriceRatioFp);
    });

    it('should return startFourthRootPriceRatioFp when currentTime < startTime', async () => {
      const currentTime = 0;
      const startFourthRootPriceRatioFp = bn(100e18);
      const endFourthRootPriceRatioFp = bn(300e18);
      const priceRatioUpdateStartTime = 1;
      const priceRatioUpdateEndTime = 50;

      const contractResult = await mathLib.calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );
      const mathResult = calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(startFourthRootPriceRatioFp);
    });

    it('should return endFourthRootPriceRatioFp when startFourthRootPriceRatioFp == endFourthRootPriceRatioFp', async () => {
      const currentTime = 25;
      const startFourthRootPriceRatioFp = bn(100e18);
      const endFourthRootPriceRatioFp = bn(100e18);
      const priceRatioUpdateStartTime = 1;
      const priceRatioUpdateEndTime = 50;

      const contractResult = await mathLib.calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );
      const mathResult = calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(endFourthRootPriceRatioFp);
    });

    it('should return the correct value when currentTime < endTime && currentTime > startTime', async () => {
      const currentTime = 25;
      const startFourthRootPriceRatioFp = bn(100e18);
      const endFourthRootPriceRatioFp = bn(300e18);
      const priceRatioUpdateStartTime = 1;
      const priceRatioUpdateEndTime = 50;

      const contractResult = await mathLib.calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );
      const mathResult = calculateFourthRootPriceRatio(
        currentTime,
        startFourthRootPriceRatioFp,
        endFourthRootPriceRatioFp,
        priceRatioUpdateStartTime,
        priceRatioUpdateEndTime
      );

      expectEqualWithError(contractResult, mathResult, EXPECTED_RELATIVE_ERROR);
      expect(contractResult).to.not.equal(startFourthRootPriceRatioFp);
      expect(contractResult).to.not.equal(endFourthRootPriceRatioFp);
    });
  });

  context('getCurrentVirtualBalances', () => {
    const computeCheckAndReturnContractVirtualBalances = async (
      balancesScaled18: bigint[],
      lastVirtualBalances: bigint[],
      lastTimestamp: number,
      priceRatioState: PriceRatioState,
      expectChange: boolean
    ): Promise<{
      virtualBalances: bigint[];
    }> => {
      await (await mathLib.setPriceRatioState(priceRatioState)).wait();

      const [contractCurrentVirtualBalances, contractChanged] = await mathLib.getCurrentVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        CENTEREDNESS_MARGIN
      );

      const blockTimestamp = await getTimestampFromLastBlock();

      const [jsCurrentVirtualBalances, jsChanged] = getCurrentVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        blockTimestamp,
        CENTEREDNESS_MARGIN,
        priceRatioState
      );

      expect(contractCurrentVirtualBalances.length).to.equal(jsCurrentVirtualBalances.length);
      expect(contractCurrentVirtualBalances.length).to.equal(2);
      expectEqualWithError(contractCurrentVirtualBalances[0], jsCurrentVirtualBalances[0], EXPECTED_RELATIVE_ERROR);
      expectEqualWithError(contractCurrentVirtualBalances[1], jsCurrentVirtualBalances[1], EXPECTED_RELATIVE_ERROR);
      expect(contractChanged).to.equal(jsChanged);
      expect(contractChanged).to.equal(expectChange);

      return { virtualBalances: [contractCurrentVirtualBalances[0], contractCurrentVirtualBalances[1]] };
    };

    it('q is updating & isPoolInRange == true && lastTimestamp < startTime', async () => {
      // Price ratio is updating. (priceRatioState.endTime > currentTimestamp)
      const priceRatioState = await getPriceRatioState(1000);
      const lastTimestamp = priceRatioState.priceRatioUpdateStartTime - 100;

      const balancesScaled18 = BALANCES_IN_RANGE;
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      const contractVirtualBalances = await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        lastTimestamp,
        priceRatioState,
        true
      );

      expect(
        await mathLib.isPoolInRange(balancesScaled18, contractVirtualBalances.virtualBalances, CENTEREDNESS_MARGIN)
      ).to.equal(true);
    });

    it('q is updating & isPoolInRange == true && lastTimestamp > startTime', async () => {
      const priceRatioState = await getPriceRatioState();

      const balancesScaled18 = BALANCES_IN_RANGE;
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      // Price ratio is updating.
      const lastTimestamp = priceRatioState.priceRatioUpdateStartTime + 20;

      const res = await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        lastTimestamp,
        priceRatioState,
        true
      );

      expect(await mathLib.isPoolInRange(balancesScaled18, res.virtualBalances, CENTEREDNESS_MARGIN)).to.equal(true);
    });

    it('q is not updating & isPoolInRange == false && isAboveCenter == true', async () => {
      const priceRatioState = await getPriceRatioState();

      const balancesScaled18 = BALANCES_OUT_OF_RANGE;
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      // Price ratio is not updating.
      const lastTimestamp = priceRatioState.priceRatioUpdateEndTime + 50;

      expect(await mathLib.isAboveCenter(balancesScaled18, lastVirtualBalances)).to.equal(true);
      expect(await mathLib.isPoolInRange(balancesScaled18, lastVirtualBalances, CENTEREDNESS_MARGIN)).to.equal(false);

      await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        lastTimestamp,
        priceRatioState,
        true
      );
    });

    it('q is not updating & isPoolInRange == false && isAboveCenter == false', async () => {
      const priceRatioState = await getPriceRatioState();

      const balancesScaled18 = [BALANCES_OUT_OF_RANGE[1], BALANCES_OUT_OF_RANGE[0]];
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      // Price ratio is not updating.
      const lastTimestamp = priceRatioState.priceRatioUpdateEndTime + 50;

      expect(await mathLib.isAboveCenter(balancesScaled18, lastVirtualBalances)).to.equal(false);
      expect(await mathLib.isPoolInRange(balancesScaled18, lastVirtualBalances, CENTEREDNESS_MARGIN)).to.equal(false);

      await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        lastTimestamp,
        priceRatioState,
        true
      );
    });
  });

  context('pureComputeInvariant', () => {
    it('should return the correct value (roundUp)', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const virtualBalances = [bn(100e18), bn(100e18)];
      const rounding = Rounding.ROUND_UP;

      const res = await mathLib.computeInvariant(balancesScaled18, virtualBalances, rounding);
      expect(res).to.equal(pureComputeInvariant(balancesScaled18, virtualBalances, rounding));
    });

    it('should return the correct value (roundDown)', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const virtualBalances = [bn(100e18), bn(100e18)];
      const rounding = Rounding.ROUND_DOWN;

      const res = await mathLib.computeInvariant(balancesScaled18, virtualBalances, rounding);
      expect(res).to.equal(pureComputeInvariant(balancesScaled18, virtualBalances, rounding));
    });
  });

  context('computeInvariant', () => {
    it('should return the correct value (roundUp)', async () => {
      // Price ratio is updating. (priceRatioState.endTime > currentTimestamp)
      const priceRatioState = await getPriceRatioState(1000);
      const lastTimestamp = priceRatioState.priceRatioUpdateStartTime - 100;

      const balancesScaled18 = BALANCES_IN_RANGE;
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      const rounding = Rounding.ROUND_UP;

      await (await mathLib.setPriceRatioState(priceRatioState)).wait();

      const res = await mathLib.computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        CENTEREDNESS_MARGIN,
        rounding
      );

      // Make sure the timestamp used for offchain calculations matches the one used by the lib.
      const currentTimestamp = await getTimestampFromLastBlock();

      const jsRes = computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        currentTimestamp,
        CENTEREDNESS_MARGIN,
        priceRatioState,
        rounding
      );

      // Small error, due to pow function implementation.
      expectEqualWithError(res, jsRes, 1e-16);
    });

    it('should return the correct value (roundDown)', async () => {
      // Price ratio is updating. (priceRatioState.endTime > currentTimestamp)
      const priceRatioState = await getPriceRatioState(1000);
      const lastTimestamp = priceRatioState.priceRatioUpdateStartTime - 100;

      const balancesScaled18 = BALANCES_IN_RANGE;
      const lastVirtualBalances = INITIAL_VIRTUAL_BALANCES;

      const rounding = Rounding.ROUND_DOWN;

      await (await mathLib.setPriceRatioState(priceRatioState)).wait();

      const res = await mathLib.computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        CENTEREDNESS_MARGIN,
        rounding
      );

      // Make sure the timestamp used for offchain calculations matches the one used by the lib.
      const currentTimestamp = await getTimestampFromLastBlock();

      const jsRes = computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        TIME_CONSTANT,
        lastTimestamp,
        currentTimestamp,
        CENTEREDNESS_MARGIN,
        priceRatioState,
        rounding
      );

      // Small error, due to pow function implementation.
      expectEqualWithError(res, jsRes, 1e-16);
    });
  });
});
