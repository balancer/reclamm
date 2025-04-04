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

type PriceRatioState = {
  startTime: number;
  endTime: number;
  startFourthRootPriceRatio: bigint;
  endFourthRootPriceRatio: bigint;
};

export function getCurrentVirtualBalances(
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  timeConstant: bigint,
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

  const currentFourthRootPriceRatio = calculateFourthRootPriceRatio(
    currentTimestamp,
    priceRatioState.startFourthRootPriceRatio,
    priceRatioState.endFourthRootPriceRatio,
    priceRatioState.startTime,
    priceRatioState.endTime
  );

  const isPoolAboveCenter = isAboveCenter(balancesScaled18, lastVirtualBalances);

  if (
    priceRatioState.startTime != 0 &&
    currentTimestamp > priceRatioState.startTime &&
    (currentTimestamp < priceRatioState.endTime || lastTimestamp < priceRatioState.endTime)
  ) {
    virtualBalances = calculateVirtualBalancesUpdatingPriceRatio(
      currentFourthRootPriceRatio,
      balancesScaled18,
      lastVirtualBalances,
      isPoolAboveCenter
    );
    changed = true;
  }

  if (isPoolInRange(balancesScaled18, lastVirtualBalances, centerednessMargin) == false) {
    const priceRatio = fpMulDown(currentFourthRootPriceRatio, currentFourthRootPriceRatio);

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
  currentFourthRootPriceRatio: bigint,
  balancesScaled18: bigint[],
  lastVirtualBalances: bigint[],
  isPoolAboveCenter: boolean
): bigint[] {
  let virtualBalances = [...lastVirtualBalances];

  const centeredness = calculateCenteredness(balancesScaled18, lastVirtualBalances);

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
  timeConstant: bigint,
  lastTimestamp: number,
  currentTimestamp: number,
  centerednessMargin: bigint,
  priceRatioState: PriceRatioState,
  rounding: Rounding
): bigint {
  const [currentVirtualBalances, _] = getCurrentVirtualBalances(
    balancesScaled18,
    lastVirtualBalances,
    timeConstant,
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

export function initializeVirtualBalances(balancesScaled18: bigint[], fourthRootPriceRatio: bigint): bigint[] {
  const virtualBalances = [0n, 0n];
  virtualBalances[0] = fpDivDown(balancesScaled18[0], fourthRootPriceRatio - FP_ONE);
  virtualBalances[1] = fpDivDown(balancesScaled18[1], fourthRootPriceRatio - FP_ONE);

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

export function calculateFourthRootPriceRatio(
  currentTime: number,
  startFourthRootPriceRatio: BigNumberish,
  endFourthRootPriceRatio: BigNumberish,
  startTime: number,
  endTime: number
): bigint {
  if (currentTime <= startTime) {
    return bn(startFourthRootPriceRatio);
  } else if (currentTime >= endTime) {
    return bn(endFourthRootPriceRatio);
  } else if (startFourthRootPriceRatio == endFourthRootPriceRatio) {
    return bn(endFourthRootPriceRatio);
  }

  const exponent = fromFp(fpDivDown(currentTime - startTime, endTime - startTime));

  return fpDivDown(
    fpMulDown(startFourthRootPriceRatio, fp(fromFp(endFourthRootPriceRatio).pow(exponent))),
    fp(fromFp(startFourthRootPriceRatio).pow(exponent))
  );
}

export function isAboveCenter(balancesScaled18: bigint[], virtualBalances: bigint[]): boolean {
  if (balancesScaled18[1] == 0n) {
    return true;
  } else {
    return fpDivDown(balancesScaled18[0], balancesScaled18[1]) > fpDivDown(virtualBalances[0], virtualBalances[1]);
  }
}

export function computePriceShiftDailyRate(priceShiftDailyRate: bigint): bigint {
  return bn(priceShiftDailyRate) / bn(124649);
}
