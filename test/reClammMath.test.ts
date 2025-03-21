import { Contract } from 'ethers';
import { deploy } from '@balancer-labs/v3-helpers/src/contract';
import { expect } from 'chai';
import { bn } from '@balancer-labs/v3-helpers/src/numbers';
import {
  calculateCenteredness,
  calculateInGivenOut,
  calculateOutGivenIn,
  calculateSqrtQ0,
  computeInvariant,
  getVirtualBalances,
  initializeVirtualBalances,
  isAboveCenter,
  isPoolInRange,
  parseIncreaseDayRate,
  pureComputeInvariant,
  Rounding,
} from './utils/reClammMath';
import { expectEqualWithError } from './utils/relativeError';

describe('ReClammMath', function () {
  const EXPECTED_RELATIVE_ERROR = 1e-12;

  let mathLib: Contract;

  before(async function () {
    mathLib = await deploy('ReClammMathMock');
  });

  context('parseIncreaseDayRate', () => {
    it('should return the correct value', async () => {
      const increaseDayRate = bn(1000e18);
      const contractResult = await mathLib.parseIncreaseDayRate(increaseDayRate);

      expect(contractResult).to.equal(parseIncreaseDayRate(increaseDayRate));
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
      const centerednessMargin = bn(0);

      const res = await mathLib.isPoolInRange(balances, virtualBalances, centerednessMargin);
      expect(res).to.equal(isPoolInRange(balances, virtualBalances, centerednessMargin));
      expect(res).to.equal(true);
    });

    it('centeredness < centerednessMargin', async () => {
      const balances = [bn(100e18), bn(100e18)];
      const virtualBalances = [bn(110e18), bn(100e18)];
      const centerednessMargin = bn(100e18);

      const res = await mathLib.isPoolInRange(balances, virtualBalances, centerednessMargin);
      expect(res).to.equal(isPoolInRange(balances, virtualBalances, centerednessMargin));
      expect(res).to.equal(false);
    });
  });

  context('initializeVirtualBalances', () => {
    it('should return the correct value', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const sqrtQ0 = bn(100e18);

      const res = await mathLib.initializeVirtualBalances(balancesScaled18, sqrtQ0);
      const jsRes = initializeVirtualBalances(balancesScaled18, sqrtQ0);
      expect(res.length).to.equal(jsRes.length);
      expect(res[0]).to.equal(jsRes[0]);
      expect(res[1]).to.equal(jsRes[1]);
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

  context('calculateSqrtQ0', () => {
    it('should return endSqrtQ0Fp when currentTime > endTime', async () => {
      const currentTime = 100;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(300e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mathLib.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(endSqrtQ0Fp);
    });

    it('should return startSqrtQ0Fp when currentTime < startTime', async () => {
      const currentTime = 0;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(300e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mathLib.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(startSqrtQ0Fp);
    });

    it('should return endSqrtQ0Fp when startSqrtQ0Fp == endSqrtQ0Fp', async () => {
      const currentTime = 25;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(100e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mathLib.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expect(contractResult).to.equal(mathResult);
      expect(contractResult).to.equal(endSqrtQ0Fp);
    });

    it('should return the correct value when currentTime < endTime && currentTime > startTime', async () => {
      const currentTime = 25;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(300e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mathLib.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expectEqualWithError(contractResult, mathResult, EXPECTED_RELATIVE_ERROR);
      expect(contractResult).to.not.equal(startSqrtQ0Fp);
      expect(contractResult).to.not.equal(endSqrtQ0Fp);
    });
  });

  context('getVirtualBalances', () => {
    const computeCheckAndReturnContractVirtualBalances = async (
      balancesScaled18: bigint[],
      lastVirtualBalances: bigint[],
      timeConstant: bigint,
      lastTimestamp: number,
      currentTimestamp: number,
      centerednessMargin: bigint,
      sqrtQ0State: { startTime: number; endTime: number; startSqrtQ0: bigint; endSqrtQ0: bigint },
      expectChange: boolean
    ): Promise<{
      virtualBalances: bigint[];
    }> => {
      await (await mathLib.setSqrtQ0State(sqrtQ0State)).wait();

      const contractVirtualBalances = await mathLib.getVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin
      );

      const javascriptVirtualBalances = getVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State
      );

      expect(contractVirtualBalances[0].length).to.equal(javascriptVirtualBalances[0].length);
      expect(contractVirtualBalances[0].length).to.equal(2);
      expectEqualWithError(contractVirtualBalances[0][0], javascriptVirtualBalances[0][0], EXPECTED_RELATIVE_ERROR);
      expectEqualWithError(contractVirtualBalances[0][1], javascriptVirtualBalances[0][1], EXPECTED_RELATIVE_ERROR);
      expect(contractVirtualBalances[1]).to.equal(javascriptVirtualBalances[1]);
      expect(contractVirtualBalances[1]).to.equal(expectChange);

      return { virtualBalances: [contractVirtualBalances[0][0], contractVirtualBalances[0][1]] };
    };

    it('q is updating & isPoolInRange == true && lastTimestamp < startTime', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const startSqrtQ0 = bn(1.5e18);
      const endSqrtQ0 = bn(2e18);
      const lastVirtualBalances = initializeVirtualBalances(balancesScaled18, startSqrtQ0);
      const timeConstant = bn(1e18);
      const lastTimestamp = 5;
      const currentTimestamp = 20;
      const centerednessMargin = 20n;
      const sqrtQ0State = {
        startTime: 10,
        endTime: 50,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: endSqrtQ0,
      };

      const contractVirtualBalances = await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
        true
      );

      expect(
        await mathLib.isPoolInRange(balancesScaled18, contractVirtualBalances.virtualBalances, centerednessMargin)
      ).to.equal(true);
    });

    it('q is updating & isPoolInRange == true && lastTimestamp > startTime', async () => {
      const balancesScaled18 = [bn(200e18), bn(300e18)];
      const startSqrtQ0 = bn(1.5e18);
      const endSqrtQ0 = bn(2e18);
      const lastVirtualBalances = initializeVirtualBalances(balancesScaled18, startSqrtQ0);
      const timeConstant = bn(1e18);
      const lastTimestamp = 15;
      const currentTimestamp = 20;
      const centerednessMargin = 0n;
      const sqrtQ0State = {
        startTime: 10,
        endTime: 50,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: endSqrtQ0,
      };

      const res = await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
        true
      );

      expect(await mathLib.isPoolInRange(balancesScaled18, res.virtualBalances, centerednessMargin)).to.equal(true);
    });

    it('q is not updating & isPoolInRange == false && isAboveCenter == true', async () => {
      const balancesScaled18 = [bn(200e18), bn(200e18)];
      const startSqrtQ0 = bn(1.5e18);
      const lastVirtualBalances = [bn(200e18), balancesScaled18[1] * 2n];
      const timeConstant = bn(0);
      const lastTimestamp = 15;
      const currentTimestamp = 20;
      const centerednessMargin = bn(100e18);
      const sqrtQ0State = {
        startTime: 0,
        endTime: 0,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: startSqrtQ0,
      };

      expect(await mathLib.isAboveCenter(balancesScaled18, lastVirtualBalances)).to.equal(true);
      expect(await mathLib.isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin)).to.equal(false);

      await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
        true
      );
    });

    it('q is not updating & isPoolInRange == false && isAboveCenter == false', async () => {
      const balancesScaled18 = [bn(200e18), bn(200e18)];
      const startSqrtQ0 = bn(1.5e18);
      const lastVirtualBalances = initializeVirtualBalances(balancesScaled18, startSqrtQ0);
      const timeConstant = bn(0);
      const lastTimestamp = 15;
      const currentTimestamp = 20;
      const centerednessMargin = bn(100e18);
      const sqrtQ0State = {
        startTime: 0,
        endTime: 0,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: startSqrtQ0,
      };

      expect(await mathLib.isAboveCenter(balancesScaled18, lastVirtualBalances)).to.equal(false);
      expect(await mathLib.isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin)).to.equal(false);

      await computeCheckAndReturnContractVirtualBalances(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
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
      const balancesScaled18 = [bn(200e18), bn(200e18)];
      const startSqrtQ0 = bn(1.5e18);
      const lastVirtualBalances = initializeVirtualBalances(balancesScaled18, startSqrtQ0);
      const timeConstant = bn(0);
      const lastTimestamp = 15;
      const currentTimestamp = 20;
      const centerednessMargin = bn(100e18);
      const sqrtQ0State = {
        startTime: 0,
        endTime: 0,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: startSqrtQ0,
      };

      const rounding = Rounding.ROUND_UP;

      await (await mathLib.setSqrtQ0State(sqrtQ0State)).wait();

      const res = await mathLib.computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        rounding
      );
      const jsRes = computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
        rounding
      );

      expect(res).to.equal(jsRes);
    });

    it('should return the correct value (roundDown)', async () => {
      const balancesScaled18 = [bn(200e18), bn(200e18)];
      const startSqrtQ0 = bn(1.5e18);
      const lastVirtualBalances = initializeVirtualBalances(balancesScaled18, startSqrtQ0);
      const timeConstant = bn(0);
      const lastTimestamp = 15;
      const currentTimestamp = 20;
      const centerednessMargin = bn(100e18);
      const sqrtQ0State = {
        startTime: 0,
        endTime: 0,
        startSqrtQ0: startSqrtQ0,
        endSqrtQ0: startSqrtQ0,
      };

      const rounding = Rounding.ROUND_DOWN;

      await (await mathLib.setSqrtQ0State(sqrtQ0State)).wait();

      const res = await mathLib.computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        rounding
      );
      const jsRes = computeInvariant(
        balancesScaled18,
        lastVirtualBalances,
        timeConstant,
        lastTimestamp,
        currentTimestamp,
        centerednessMargin,
        sqrtQ0State,
        rounding
      );

      expect(res).to.equal(jsRes);
    });
  });
});
