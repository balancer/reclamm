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
  timeConstant: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtPriceRatioState: SqrtPriceRatioState
): [bigint[], boolean] {
  let virtualBalances = [...lastVirtualBalances];

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

  const isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

  if (
    sqrtPriceRatioState.startTime != 0 &&
    currentTimestamp > sqrtPriceRatioState.startTime &&
    (currentTimestamp < sqrtPriceRatioState.endTime || lastTimestamp < sqrtPriceRatioState.endTime)
  ) {
    virtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
      currentSqrtPriceRatio,
      balancesScaled18,
      lastVirtualBalances,
      isPoolAboveCenter
    );
    changed = true;
  }

  if (isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin) == false) {
    const priceRatio = fpMulDown(currentSqrtPriceRatio, currentSqrtPriceRatio);

    const base = fromFp(FP_ONE - timeConstant);
    const exponent = fromFp(fp(currentTimestamp - lastTimestamp));
    const powResult = base.pow(exponent);

    if (isPoolAboveCenter) {
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

export function calculateVirtualBalancesUpdatingPriceRatio(
  currentSqrtPriceRatio: bigint,
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  isPoolAboveCenter: boolean
): bigint[] {
  let virtualBalances = [...lastVirtualBalances];

  const centeredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

  if (isPoolAboveCenter) {
    const a = fpMulDown(currentSqrtPriceRatio, currentSqrtPriceRatio) - fp(1);
    const b = fpMulDown(balancesScaled18[0], fp(1) + centeredness);
    const c = fpMulDown(fpMulDown(balancesScaled18[0], balancesScaled18[0]), centeredness);

    virtualBalances[0] = fpDivDown(
      b + BigInt(Math.sqrt(Number(fp(1) * (fpMulDown(b, b) + fpMulDown(fp(4), fpMulDown(a, c)))))),
      fpMulDown(fp(2), a)
    );
    virtualBalances[1] = fpDivDown(
      fpDivDown(fpMulDown(balancesScaled18[1], virtualBalances[0]), balancesScaled18[0]),
      centeredness
    );
  } else {
    const a = fpMulDown(currentSqrtPriceRatio, currentSqrtPriceRatio) - fp(1);
    const b = fpMulDown(balancesScaled18[1], fp(1) + centeredness);
    const c = fpMulDown(fpMulDown(balancesScaled18[1], balancesScaled18[1]), centeredness);

    virtualBalances[1] = fpDivDown(
      b + BigInt(Math.sqrt(Number(fp(1) * (fpMulDown(b, b) + fpMulDown(fp(4), fpMulDown(a, c)))))),
      fpMulDown(fp(2), a)
    );
    virtualBalances[0] = fpDivDown(
      fpDivDown(fpMulDown(balancesScaled18[0], virtualBalances[1]), balancesScaled18[1]),
      centeredness
    );
  }

  return virtualBalances;
}

export function computeInvariant(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  timeConstant: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  sqrtPriceRatioState: SqrtPriceRatioState,
  rounding: Rounding
): bigint {
  const [virtualBalances, _] = getVirtualBalances(
    balancesScaled18,
    lastVirtualBalances,
    timeConstant,
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
    return fpDivDown(balancesScaled18[0], balancesScaled18[1]) > fpDivDown(virtualBalances[0], virtualBalances[1]);
  }
}

export function parseIncreaseDayRate(increaseDayRate: bigint): bigint {
  return bn(increaseDayRate) / bn(124649);
}
