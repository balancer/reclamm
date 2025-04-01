import { expect } from 'chai';
import { BigNumberish } from 'ethers';
import { bn, pct } from '../../lib/balancer-v3-monorepo/pvt/helpers/src/numbers';

export function expectEqualWithError(
  actual: BigNumberish,
  expected: BigNumberish,
  error: BigNumberish = 0.001,
  message?: string
): void {
  actual = bn(actual);
  expected = bn(expected);
  const acceptedError = pct(expected, error);

  const absoluteError = Math.abs(Number(actual - expected));

  expect(absoluteError).to.be.at.most(Number(acceptedError), message);
}
