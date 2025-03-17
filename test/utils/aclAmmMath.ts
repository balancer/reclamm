import { BigNumberish } from 'ethers';
import { bn } from '@balancer-labs/v3-helpers/src/numbers';

export function calculateSqrtQ0(
  currentTime: number,
  startSqrtQ0Fp: BigNumberish,
  endSqrtQ0Fp: BigNumberish,
  startTime: number,
  endTime: number
): bigint {
  if (currentTime < startTime) {
    return bn(startSqrtQ0Fp);
  } else if (currentTime >= endTime) {
    return bn(endSqrtQ0Fp);
  }

  const exponent = bn(currentTime - startTime) / bn(endTime - startTime);
  const base = bn(endSqrtQ0Fp) / bn(startSqrtQ0Fp);

  return bn(startSqrtQ0Fp) * base ** exponent;
}
