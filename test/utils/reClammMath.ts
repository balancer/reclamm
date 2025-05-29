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

export type BalancesAndPriceRatio = {
  realBalances: bigint[];
  virtualBalances: bigint[];
  priceRatio: bigint;
};

export type PriceRatioState = {
  priceRatioUpdateStartTime: number;
  priceRatioUpdateEndTime: number;
  startFourthRootPriceRatio: bigint;
  endFourthRootPriceRatio: bigint;
};

const _INITIALIZATION_MAX_BALANCE_A = fp(1000000);

export function computeCurrentVirtualBalances(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  dailyPriceShiftBase: bigint,
  lastTimestamp: bigint,
  currentTimestamp: bigint,
  centerednessMargin: bigint,
  priceRatioState: PriceRatioState
): [bigint[], boolean] {
  let virtualBalances = [...lastVirtualBalances];

  if (lastTimestamp == currentTimestamp) {
    return [virtualBalances, false];
  }

  let changed = false;

  const currentFourthRootPriceRatio = computeFourthRootPriceRatio(
    currentTimestamp,
    priceRatioState.startFourthRootPriceRatio,
    priceRatioState.endFourthRootPriceRatio,
    priceRatioState.priceRatioUpdateStartTime,
    priceRatioState.priceRatioUpdateEndTime
  );

  const isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

  if (
    priceRatioState.priceRatioUpdateStartTime != 0 &&
    currentTimestamp > priceRatioState.priceRatioUpdateStartTime &&
    (currentTimestamp < priceRatioState.priceRatioUpdateEndTime ||
      lastTimestamp < priceRatioState.priceRatioUpdateEndTime)
  ) {
    virtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
      currentFourthRootPriceRatio,
      balancesScaled18,
      lastVirtualBalances,
      isPoolAboveCenter
    );
    changed = true;
  }

  if (isPoolWithinTargetRange(balancesScaled18, virtualBalances, centerednessMargin) == false) {
    const sqrtPriceRatio = bn(Math.sqrt(Number(computeCurrentPriceRatio(balancesScaled18, virtualBalances) * FP_ONE)));

    const exponent = fp(currentTimestamp - lastTimestamp);
    const powResult = powDown(dailyPriceShiftBase, exponent);

    if (isPoolAboveCenter) {
      virtualBalances[1] = fpMulDown(virtualBalances[1], powResult);
      virtualBalances[0] = fpDivDown(
        fpMulDown(balancesScaled18[0], virtualBalances[1] + balancesScaled18[1]),
        fpMulDown(sqrtPriceRatio - FP_ONE, virtualBalances[1]) - balancesScaled18[1]
      );
    } else {
      virtualBalances[0] = fpMulDown(virtualBalances[0], powResult);
      virtualBalances[1] = fpDivDown(
        fpMulDown(balancesScaled18[1], virtualBalances[0] + balancesScaled18[0]),
        fpMulDown(sqrtPriceRatio - FP_ONE, virtualBalances[0]) - balancesScaled18[0]
      );
    }

    changed = true;
  }

  return [virtualBalances, changed];
}

function computeCurrentPriceRatio(balancesScaled18: bigint[], virtualBalances: bigint[]): bigint {
  const [minPrice, maxPrice] = computeCurrentPriceRange(balancesScaled18, virtualBalances);
  return fpDivUp(maxPrice, minPrice);
}

function computeCurrentPriceRange(balancesScaled18: bigint[], virtualBalances: bigint[]): [bigint, bigint] {
  const invariant = pureComputeInvariant(balancesScaled18, virtualBalances, Rounding.ROUND_DOWN);

  const minPrice = (virtualBalances[1] * virtualBalances[1]) / invariant;
  const maxPrice = fpDivDown(invariant, fpMulDown(virtualBalances[0], virtualBalances[0]));

  return [minPrice, maxPrice];
}

export function calculateVirtualBalancesUpdatingPriceRatio(
  currentFourthRootPriceRatio: bigint,
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  isPoolAboveCenter: boolean
): bigint[] {
  let virtualBalances = [...lastVirtualBalances];

  const centeredness = computeCenteredness(balancesScaled18, lastVirtualBalances);

  if (isPoolAboveCenter) {
    const a = fpMulDown(currentFourthRootPriceRatio, currentFourthRootPriceRatio) - fp(1);
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
    const a = fpMulDown(currentFourthRootPriceRatio, currentFourthRootPriceRatio) - fp(1);
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
  dailyPriceShiftBase: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  priceRatioState: PriceRatioState,
  rounding: Rounding
): bigint {
  const [currentVirtualBalances, _] = computeCurrentVirtualBalances(
    balancesScaled18,
    lastVirtualBalances,
    dailyPriceShiftBase,
    lastTimestamp,
    currentTimestamp,
    centerednessMargin,
    priceRatioState
  );

  return pureComputeInvariant(balancesScaled18, currentVirtualBalances, rounding);
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

export function computeTheoreticalPriceRatioAndBalances(
  minPrice: bigint,
  maxPrice: bigint,
  targetPrice: bigint
): BalancesAndPriceRatio {
  const priceRatio: bigint = fpDivDown(maxPrice, minPrice);
  const sqrtPriceRatio: bigint = bn(Math.sqrt(Number(priceRatio * FP_ONE)));

  const virtualBalances: bigint[] = [];
  virtualBalances[0] = fpDivDown(_INITIALIZATION_MAX_BALANCE_A, sqrtPriceRatio - FP_ONE);
  virtualBalances[1] = fpMulDown(minPrice, virtualBalances[0] + _INITIALIZATION_MAX_BALANCE_A);

  const realBalances: bigint[] = [];
  realBalances[1] =
    bn(
      Math.sqrt(
        Number(
          fpMulUp(fpMulUp(targetPrice, virtualBalances[1]), _INITIALIZATION_MAX_BALANCE_A + virtualBalances[0]) * FP_ONE
        )
      )
    ) - virtualBalances[1];
  realBalances[0] = fpDivDown(
    realBalances[1] + virtualBalances[1] - fpMulDown(virtualBalances[0], targetPrice),
    targetPrice
  );

  return { realBalances, virtualBalances, priceRatio };
}

export function isPoolWithinTargetRange(
  balancesScaled18: bigint[],
  virtualBalances: bigint[],
  centerednessMargin: bigint
): boolean {
  const centeredness = computeCenteredness(balancesScaled18, virtualBalances);
  return centeredness >= centerednessMargin;
}

export function computeCenteredness(balancesScaled18: bigint[], virtualBalances: bigint[]): bigint {
  if (balancesScaled18[0] == 0n || balancesScaled18[1] == 0n) {
    return 0n;
  }

  const isPoolAboveCenter = isAboveCenter(balancesScaled18, virtualBalances);

  const [indexTokenUndervalued, indexTokenOvervalued] = isPoolAboveCenter ? [0, 1] : [1, 0];

  return fpDivDown(
    (balancesScaled18[indexTokenOvervalued] * virtualBalances[indexTokenUndervalued]) /
      balancesScaled18[indexTokenUndervalued],
    virtualBalances[indexTokenOvervalued]
  );
}

export function computeFourthRootPriceRatio(
  currentTime: number,
  startFourthRootPriceRatio: bigint,
  endFourthRootPriceRatio: bigint,
  priceRatioUpdateStartTime: number,
  priceRatioUpdateEndTime: number
): bigint {
  if (currentTime <= priceRatioUpdateStartTime) {
    return bn(startFourthRootPriceRatio);
  } else if (currentTime >= priceRatioUpdateEndTime) {
    return bn(endFourthRootPriceRatio);
  } else if (startFourthRootPriceRatio == endFourthRootPriceRatio) {
    return bn(endFourthRootPriceRatio);
  }

  const exponent = fpDivDown(
    currentTime - priceRatioUpdateStartTime,
    priceRatioUpdateEndTime - priceRatioUpdateStartTime
  );

  return (
    (startFourthRootPriceRatio * powDown(endFourthRootPriceRatio, exponent)) /
    powDown(startFourthRootPriceRatio, exponent)
  );
}

export function isAboveCenter(balancesScaled18: bigint[], virtualBalances: bigint[]): boolean {
  if (balancesScaled18[1] == 0n) {
    return true;
  } else {
    return fpDivDown(balancesScaled18[0], balancesScaled18[1]) > fpDivDown(virtualBalances[0], virtualBalances[1]);
  }
}

export function toDailyPriceShiftBase(dailyPriceShiftExponent: bigint): bigint {
  return fp(1) - bn(dailyPriceShiftExponent) / bn(124649);
}

export function pow4(value: bigint): bigint {
  return powDown(value, fp(4));
}

export function fourthRoot(value: bigint): bigint {
  return bn(Math.sqrt(Number(BigInt(Math.sqrt(Number(value * FP_ONE))) * FP_ONE)));
}

export function computePriceRange(
  balancesScaled18: bigint[],
  virtualBalanceA: bigint,
  virtualBalanceB: bigint
): [bigint, bigint] {
  const invariant = pureComputeInvariant(balancesScaled18, [virtualBalanceA, virtualBalanceB], Rounding.ROUND_DOWN);

  const minPrice = (virtualBalanceB * virtualBalanceB) / invariant;
  const maxPrice = fpDivDown(invariant, fpMulDown(virtualBalanceA, virtualBalanceA));

  return [minPrice, maxPrice];
}

export function computePriceRatio(
  balancesScaled18: bigint[],
  virtualBalanceA: bigint,
  virtualBalanceB: bigint
): bigint {
  const [minPrice, maxPrice] = computePriceRange(balancesScaled18, virtualBalanceA, virtualBalanceB);
  return fpDivUp(maxPrice, minPrice);
}

function powDown(x: bigint, y: bigint): bigint {
  const MAX_POW_RELATIVE_ERROR = 10000n;
  // Optimize for when y equals 1.0, 2.0 or 4.0, as those are very simple to implement.
  if (y == fp(1)) {
    return x;
  } else if (y == fp(2)) {
    return fpMulDown(x, x);
  } else if (y == fp(4)) {
    const square = fpMulDown(x, x);
    return fpMulDown(square, square);
  } else {
    const raw = fp(fromFp(x).pow(fromFp(y)));
    const maxError = fpMulUp(raw, MAX_POW_RELATIVE_ERROR) + 1n;

    if (raw < maxError) {
      return fp(0);
    } else {
      return raw - maxError;
    }
  }
}
