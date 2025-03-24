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

export enum Rounding {
  ROUND_UP,
  ROUND_DOWN,
}

type SqrtPriceRatioState = {
  startTime: number;
  endTime: number;
  startSqrtPriceRatio: bigint;
  endSqrtPriceRatio: bigint;
};

export function getVirtualBalances(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  c: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtPriceRatioState: SqrtPriceRatioState
): [bigint[], boolean] {
  let virtualBalances = lastVirtualBalances;

  if (lastTimestamp == currentTimestamp) {
    return [virtualBalances, false];
  }

  let changed = false;

  const currentSqrtPriceRatio = calculateSqrtPriceRatio(
    currentTimestamp,
    sqrtPriceRatioState.startSqrtPriceRatio,
    sqrtPriceRatioState.endSqrtPriceRatio,
    sqrtPriceRatioState.startTime,
    sqrtPriceRatioState.endTime
  );

  if (
    sqrtPriceRatioState.startTime != 0 &&
    currentTimestamp > sqrtPriceRatioState.startTime &&
    (currentTimestamp < sqrtPriceRatioState.endTime || lastTimestamp < sqrtPriceRatioState.endTime)
  ) {
    const lastSqrtPriceRatio = calculateSqrtPriceRatio(
      lastTimestamp,
      sqrtPriceRatioState.startSqrtPriceRatio,
      sqrtPriceRatioState.endSqrtPriceRatio,
      sqrtPriceRatioState.startTime,
      sqrtPriceRatioState.endTime
    );

    const rACenter = fpMulDown(lastVirtualBalances[0], lastSqrtPriceRatio - FP_ONE);

    virtualBalances[0] = fpDivDown(rACenter, currentSqrtPriceRatio - FP_ONE);

    const currentInvariant = computeInvariant(balancesScaled18, lastVirtualBalances, Rounding.ROUND_DOWN);

    virtualBalances[1] = fpDivDown(
      currentInvariant,
      fpMulDown(fpMulDown(currentSqrtPriceRatio, currentSqrtPriceRatio), virtualBalances[0])
    );

    changed = true;
  }

  if (isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin) == false) {
    const priceRatio = fpMulDown(currentSqrtPriceRatio, currentSqrtPriceRatio);

    const base = fromFp(FP_ONE - c);
    const exponent = fromFp(fp(currentTimestamp - lastTimestamp));
    const powResult = base.pow(exponent);

    if (isAboveCenter(balancesScaled18, lastVirtualBalances)) {
      virtualBalances[1] = fpMulDown(lastVirtualBalances[1], fp(powResult));
      virtualBalances[0] = fpDivDown(
        fpMulDown(balancesScaled18[0], virtualBalances[1] + balancesScaled18[1]),
        fpMulDown(priceRatio - FP_ONE, virtualBalances[1]) - balancesScaled18[1]
      );
    } else {
      virtualBalances[0] = fpMulDown(lastVirtualBalances[0], fp(powResult));
      virtualBalances[1] = fpDivDown(
        fpMulDown(balancesScaled18[1], virtualBalances[0] + balancesScaled18[0]),
        fpMulDown(priceRatio - FP_ONE, virtualBalances[0]) - balancesScaled18[0]
      );
    }

    changed = true;
  }

  return [virtualBalances, changed];
}

export function computeInvariant(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  c: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtPriceRatioState: SqrtPriceRatioState,
  rounding: Rounding
): bigint {
  const [virtualBalances, _] = getVirtualBalances(
    balancesScaled18,
    lastVirtualBalances,
    c,
    lastTimestamp,
    currentTimestamp,
    centerednessMargin,
    sqrtPriceRatioState
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

export function initializeVirtualBalances(balancesScaled18: bigint[], sqrtPriceRatio: bigint): bigint[] {
  const virtualBalances = [0n, 0n];
  virtualBalances[0] = fpDivDown(balancesScaled18[0], sqrtPriceRatio - FP_ONE);
  virtualBalances[1] = fpDivDown(balancesScaled18[1], sqrtPriceRatio - FP_ONE);

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

export function calculateSqrtPriceRatio(
  currentTime: number,
  startSqrtPriceRatio: BigNumberish,
  endSqrtPriceRatio: BigNumberish,
  startTime: number,
  endTime: number
): bigint {
  if (currentTime < startTime) {
    return bn(startSqrtPriceRatio);
  } else if (currentTime >= endTime) {
    return bn(endSqrtPriceRatio);
  } else if (startSqrtPriceRatio == endSqrtPriceRatio) {
    return bn(endSqrtPriceRatio);
  }

  const exponent = fromFp(fpDivDown(fp(currentTime - startTime), fp(endTime - startTime)));
  const base = fromFp(fpDivDown(endSqrtPriceRatio, startSqrtPriceRatio));

  return fp(fromFp(startSqrtPriceRatio).mul(base.pow(exponent)));
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
