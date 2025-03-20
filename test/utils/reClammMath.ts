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
import { sqrt } from './sqrtLib';

export enum Rounding {
  ROUND_UP,
  ROUND_DOWN,
}

type SqrtQ0State = {
  startTime: number;
  endTime: number;
  startSqrtQ0: bigint;
  endSqrtQ0: bigint;
};

export function getVirtualBalances(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  timeConstant: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtQ0State: SqrtQ0State
): [bigint[], boolean] {
  let virtualBalances = lastVirtualBalances;

  if (lastTimestamp == currentTimestamp) {
    return [virtualBalances, false];
  }

  let changed = false;

  const currentSqrtQ0 = calculateSqrtQ0(
    currentTimestamp,
    sqrtQ0State.startSqrtQ0,
    sqrtQ0State.endSqrtQ0,
    sqrtQ0State.startTime,
    sqrtQ0State.endTime
  );

  const isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

  if (
    sqrtQ0State.startTime != 0 &&
    currentTimestamp > sqrtQ0State.startTime &&
    (currentTimestamp < sqrtQ0State.endTime || lastTimestamp < sqrtQ0State.endTime)
  ) {
    const centeredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);
    const centerednessFactor = isPoolAboveCenter ? fpDivDown(fp(1), centeredness) : centeredness;

    const a = fpMulDown(currentSqrtQ0, currentSqrtQ0) - fp(1);
    const b = fpMulDown(balancesScaled18[1], fp(1) + centerednessFactor);
    const c = fpMulDown(fpMulDown(balancesScaled18[1], balancesScaled18[1]), centerednessFactor);

    virtualBalances[1] = fpDivDown(b + sqrt(fpMulDown(b, b) + fpMulDown(fp(4), fpMulDown(a, c))), fpMulDown(fp(2), a));
    virtualBalances[0] = fpDivDown(
      fpDivDown(fpMulDown(balancesScaled18[0], virtualBalances[1]), balancesScaled18[1]),
      centerednessFactor
    );

    changed = true;
  }

  if (isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin) == false) {
    const q0 = fpMulDown(currentSqrtQ0, currentSqrtQ0);

    const base = fromFp(FP_ONE - timeConstant);
    const exponent = fromFp(fp(currentTimestamp - lastTimestamp));
    const powResult = base.pow(exponent);

    if (isPoolAboveCenter) {
      virtualBalances[1] = fpMulDown(lastVirtualBalances[1], fp(powResult));
      virtualBalances[0] = fpDivDown(
        fpMulDown(balancesScaled18[0], virtualBalances[1] + balancesScaled18[1]),
        fpMulDown(q0 - FP_ONE, virtualBalances[1]) - balancesScaled18[1]
      );
    } else {
      virtualBalances[0] = fpMulDown(lastVirtualBalances[0], fp(powResult));
      virtualBalances[1] = fpDivDown(
        fpMulDown(balancesScaled18[1], virtualBalances[0] + balancesScaled18[0]),
        fpMulDown(q0 - FP_ONE, virtualBalances[0]) - balancesScaled18[0]
      );
    }

    changed = true;
  }

  return [virtualBalances, changed];
}

export function computeInvariant(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  timeConstant: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtQ0State: SqrtQ0State,
  rounding: Rounding
): bigint {
  const [virtualBalances, _] = getVirtualBalances(
    balancesScaled18,
    lastVirtualBalances,
    timeConstant,
    lastTimestamp,
    currentTimestamp,
    centerednessMargin,
    sqrtQ0State
  );

  return pureComputeInvariant(balancesScaled18, virtualBalances, rounding);
}

export function pureComputeInvariant(
  balancesScaled18: bigint[],
  virtualBalances: bigint[],
  rounding: Rounding
): bigint {
  const _mulUpOrDown = rounding == Rounding.ROUND_DOWN ? fpMulDown : fpMulUp;

  return _mulUpOrDown(balancesScaled18[0] + virtualBalances[0], balancesScaled18[1] + virtualBalances[1]);
}

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
  startSqrtQ0: BigNumberish,
  endSqrtQ0: BigNumberish,
  startTime: number,
  endTime: number
): bigint {
  if (currentTime < startTime) {
    return bn(startSqrtQ0);
  } else if (currentTime >= endTime) {
    return bn(endSqrtQ0);
  } else if (startSqrtQ0 == endSqrtQ0) {
    return bn(endSqrtQ0);
  }

  const exponent = fromFp(fpDivDown(fp(currentTime - startTime), fp(endTime - startTime)));
  const base = fromFp(fpDivDown(endSqrtQ0, startSqrtQ0));

  return fp(fromFp(startSqrtQ0).mul(base.pow(exponent)));
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
  return bn(increaseDayRate) / bn(124649);
}
