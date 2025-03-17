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

  if (actual >= 0) {
    expect(Number(actual)).to.be.at.least(Number(expected - acceptedError), message);
    expect(Number(actual)).to.be.at.most(Number(expected + acceptedError), message);
  } else {
    expect(Number(actual)).to.be.at.most(Number(expected - acceptedError), message);
    expect(Number(actual)).to.be.at.least(Number(expected + acceptedError), message);
  }
}
