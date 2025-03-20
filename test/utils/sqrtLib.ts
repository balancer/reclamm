export function sqrt(x: bigint): bigint {
  if (x < 0n) {
    throw new Error('Square root of negative number is not supported');
  }
  if (x === 0n) {
    return 0n;
  }

  // Since we're dealing with 18 decimals, we need to adjust our precision
  // We'll work with 18 decimal places (1e18)
  const DECIMALS = 18n;
  const DECIMAL_MULTIPLIER = 10n ** DECIMALS;

  // Initial guess: we'll start with a reasonable approximation
  // For numbers with 18 decimals, we shift 9 positions right (divide by 1e9)
  // to get a good starting point
  let z = (x + DECIMAL_MULTIPLIER) >> 9n;

  // We'll use Newton's method: z = (z + x/z) / 2
  // We need to maintain decimal precision throughout calculations
  let zPrev = 0n;
  while (z !== zPrev) {
    zPrev = z;
    // Calculate x/z while maintaining precision
    const tmp = (x * DECIMAL_MULTIPLIER) / z;
    // Add z + x/z and divide by 2
    z = (z + tmp) >> 1n;
  }

  return z;
}
