import { Contract } from 'ethers';
import { deploy } from '@balancer-labs/v3-helpers/src/contract';
import { expect } from 'chai';
import { bn } from '@balancer-labs/v3-helpers/src/numbers';
import {
  calculateCenteredness,
  calculateInGivenOut,
  calculateOutGivenIn,
  calculateSqrtQ0,
  initializeVirtualBalances,
  isAboveCenter,
  isPoolInRange,
  parseIncreaseDayRate,
} from './utils/aclAmmMath';
import { expectEqualWithError } from './utils/relativeError';

describe('AclAmmMath', function () {
  const EXPECTED_RELATIVE_ERROR = 1e-12;

  let mathLib: Contract;

  before(async function () {
    mathLib = await deploy('AclAmmMathMock');
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

    it('should return the correct value when currentTime < endTime', async () => {
      const currentTime = 25;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(300e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mathLib.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expectEqualWithError(contractResult, mathResult, EXPECTED_RELATIVE_ERROR);
    });
  });
});
