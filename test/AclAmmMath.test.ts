import { Contract, BigNumberish } from 'ethers';
import { deploy } from '@balancer-labs/v3-helpers/src/contract';
import { expect } from 'chai';
import { bn } from '@balancer-labs/v3-helpers/src/numbers';
import { calculateSqrtQ0 } from './utils/aclAmmMath';

describe('AclAmmMath', function () {
  let mock: Contract;

  before(async function () {
    mock = await deploy('AclAmmMathMock');
  });

  context('calculateSqrtQ0', () => {
    it('should return endSqrtQ0Fp when currentTime > endTime', async () => {
      const currentTime = 100;
      const startSqrtQ0Fp = bn(100e18);
      const endSqrtQ0Fp = bn(300e18);
      const startTime = 1;
      const endTime = 50;

      const contractResult = await mock.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
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

      const contractResult = await mock.calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);
      const mathResult = calculateSqrtQ0(currentTime, startSqrtQ0Fp, endSqrtQ0Fp, startTime, endTime);

      expect(contractResult).to.equal(mathResult);
    });
  });
});
