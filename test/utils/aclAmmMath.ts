import { BigNumberish } from 'ethers';
import {
  bn,
  fp,
  FP_ONE,
  fpDivDown,
  fpDivUp,
  fpMulDown,
  fpMulUp,
  fromFp,
  toFp,
} from '@balancer-labs/v3-helpers/src/numbers';

enum Rounding {
  ROUND_UP,
  ROUND_DOWN,
}

type SqrtQ0State = {
  startTime: number;
  endTime: number;
  startSqrtQ0: bigint;
  endSqrtQ0: bigint;
};

export function calculateOutGivenIn(
  balancesScaled18: bigint[],
  virtualBalances: bigint[],
  tokenInIndex: number,
  tokenOutIndex: number,
  amountGivenScaled18: bigint
): bigint {
  const finalBalances = [0n, 0n];

  finalBalances[0] = balancesScaled18[0] + virtualBalances[0];
  finalBalances[1] = balancesScaled18[1] + virtualBalances[1];

  const invariant = fpMulUp(finalBalances[0], finalBalances[1]);

  return finalBalances[tokenOutIndex] - fpDivUp(invariant, finalBalances[tokenInIndex] + amountGivenScaled18);
}

export function calculateInGivenOut(
  balancesScaled18: bigint[],
  virtualBalances: bigint[],
  tokenInIndex: number,
  tokenOutIndex: number,
  amountGivenScaled18: bigint
): bigint {
  const finalBalances = [0n, 0n];

  finalBalances[0] = balancesScaled18[0] + virtualBalances[0];
  finalBalances[1] = balancesScaled18[1] + virtualBalances[1];

  const invariant = fpMulUp(finalBalances[0], finalBalances[1]);

  return fpDivUp(invariant, finalBalances[tokenOutIndex] - amountGivenScaled18) - finalBalances[tokenInIndex];
}

export function initializeVirtualBalances(balancesScaled18: bigint[], sqrtQ0: bigint): bigint[] {
  const virtualBalances = [0n, 0n];
  virtualBalances[0] = fpDivDown(balancesScaled18[0], sqrtQ0 - FP_ONE);
  virtualBalances[1] = fpDivDown(balancesScaled18[1], sqrtQ0 - FP_ONE);

  return virtualBalances;
}

export function isPoolInRange(
  balancesScaled18: bigint[],
  virtualBalances: bigint[],
  centerednessMargin: bigint
): boolean {
  const centeredness = calculateCenteredness(balancesScaled18, virtualBalances);
  return centeredness >= centerednessMargin;
}

export function calculateCenteredness(balancesScaled18: bigint[], virtualBalances: bigint[]): bigint {
  if (balancesScaled18[0] == 0n || balancesScaled18[1] == 0n) {
    return 0n;
  } else if (isAboveCenter(balancesScaled18, virtualBalances)) {
    return fpDivDown(
      fpMulDown(balancesScaled18[1], virtualBalances[0]),
      fpMulDown(balancesScaled18[0], virtualBalances[1])
    );
  } else {
    return fpDivDown(
      fpMulDown(balancesScaled18[0], virtualBalances[1]),
      fpMulDown(balancesScaled18[1], virtualBalances[0])
    );
  }
}

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

  const exponent = fromFp(fpDivDown(fp(currentTime - startTime), fp(endTime - startTime)));
  const base = fromFp(fpDivDown(endSqrtQ0Fp, startSqrtQ0Fp));

  return fp(fromFp(startSqrtQ0Fp).mul(base.pow(exponent)));
}

export function isAboveCenter(balancesScaled18: bigint[], virtualBalances: bigint[]): boolean {
  if (balancesScaled18[1] == 0n) {
    return true;
  } else {
    const fpBalancesScaled18 = new Array(2);
    const fpVirtualBalances = new Array(2);

    fpBalancesScaled18[0] = toFp(balancesScaled18[0]);
    fpBalancesScaled18[1] = toFp(balancesScaled18[1]);
    fpVirtualBalances[0] = toFp(virtualBalances[0]);
    fpVirtualBalances[1] = toFp(virtualBalances[1]);

    return fpBalancesScaled18[0].div(fpBalancesScaled18[1]) > fpVirtualBalances[0].div(fpVirtualBalances[1]);
  }
}

export function parseIncreaseDayRate(increaseDayRate: bigint): bigint {
  return bn(increaseDayRate) / bn(110000);
}
