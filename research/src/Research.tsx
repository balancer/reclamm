import React, { useState, useMemo, useEffect } from 'react';
import { TextField, Grid, Paper, Typography, Container, Button } from '@mui/material';
import PlayArrowIcon from '@mui/icons-material/PlayArrow';
import PauseIcon from '@mui/icons-material/Pause';
import { D3Chart } from './Chart';

const defaultInitialBalanceA = 1000;
const defaultInitialBalanceB = 2000;
const defaultPriceRange = 16;
const defaultMargin = 10;
const defaultPriceShiftDailyRate = 100;
const defaultSwapAmountIn = 100;

const tickMilliseconds = 20;

export default function Research() {
  const [isPlaying, setIsPlaying] = useState<boolean>(false);
  const [counter, setCounter] = useState<number>(0);
  const [lastSwapCounter, setLastSwapCounter] = useState<number>(0);
  const [speedMultiplier, setSpeedMultiplier] = useState<number>(1);
  const [isPoolInRange, setIsPoolInRange] = useState<boolean>(true);
  const [outOfRangeTime, setOutOfRangeTime] = useState<number>(0);
  const [lastRangeCheckTime, setLastRangeCheckTime] = useState<number>(0);

  const [initialBalanceA, setInitialBalanceA] = useState<number>(defaultInitialBalanceA);
  const [initialBalanceB, setInitialBalanceB] = useState<number>(defaultInitialBalanceB);
  const [priceRange, setPriceRange] = useState<number>(defaultPriceRange);
  const [margin, setMargin] = useState<number>(defaultMargin);
  const [priceShiftDailyRate, setPriceShiftDailyRate] = useState<number>(defaultPriceShiftDailyRate);

  const [inputBalanceA, setInputBalanceA] = useState<number>(defaultInitialBalanceA);
  const [inputBalanceB, setInputBalanceB] = useState<number>(defaultInitialBalanceB);
  const [inputPriceRange, setInputPriceRange] = useState<number>(defaultPriceRange);
  const [inputMargin, setInputMargin] = useState<number>(defaultMargin);

  const [currentBalanceA, setCurrentBalanceA] = useState<number>(defaultInitialBalanceA);
  const [currentBalanceB, setCurrentBalanceB] = useState<number>(defaultInitialBalanceB);
  const [virtualBalances, setVirtualBalances] = useState({ virtualBalanceA: 0, virtualBalanceB: 0 });

  const [swapTokenIn, setSwapTokenIn] = useState('Token A');
  const [swapAmountIn, setSwapAmountIn] = useState<number>(defaultSwapAmountIn);

  const invariant = useMemo(() => {
    return (currentBalanceA + virtualBalances.virtualBalanceA) * (currentBalanceB + virtualBalances.virtualBalanceB);
  }, [currentBalanceA, currentBalanceB, virtualBalances]);

  const poolCenteredness = useMemo(() => {
    if (currentBalanceA === 0 || currentBalanceB === 0) return 0;
    if (currentBalanceA / currentBalanceB > virtualBalances.virtualBalanceA / virtualBalances.virtualBalanceB) {
      return (currentBalanceB * virtualBalances.virtualBalanceA) / (currentBalanceA * virtualBalances.virtualBalanceB);
    }
    return (currentBalanceA * virtualBalances.virtualBalanceB) / (currentBalanceB * virtualBalances.virtualBalanceA);
  }, [currentBalanceA, currentBalanceB, virtualBalances]);

  const lowerMargin = useMemo(() => {
    const marginPercentage = margin / 100;
    const b = virtualBalances.virtualBalanceA + marginPercentage * virtualBalances.virtualBalanceA;
    const c =
      marginPercentage *
      (Math.pow(virtualBalances.virtualBalanceA, 2) -
        (invariant * virtualBalances.virtualBalanceA) / virtualBalances.virtualBalanceB);
    return virtualBalances.virtualBalanceA + (-b + Math.sqrt(Math.pow(b, 2) - 4 * c)) / 2;
  }, [currentBalanceA, currentBalanceB, margin, virtualBalances, invariant]);

  const higherMargin = useMemo(() => {
    const marginPercentage = margin / 100;
    const b = (virtualBalances.virtualBalanceA + marginPercentage * virtualBalances.virtualBalanceA) / marginPercentage;
    const c =
      (Math.pow(virtualBalances.virtualBalanceA, 2) -
        (virtualBalances.virtualBalanceA * invariant) / virtualBalances.virtualBalanceB) /
      marginPercentage;

    return virtualBalances.virtualBalanceA + (-b + Math.sqrt(Math.pow(b, 2) - 4 * c)) / 2;
  }, [currentBalanceA, currentBalanceB, margin, virtualBalances, invariant]);

  const chartData = useMemo(() => {
    if (priceRange <= 1) return [];

    const xForPointB = invariant / virtualBalances.virtualBalanceB;

    // Create regular curve points
    const curvePoints = Array.from({ length: 100 }, (_, i) => {
      const x =
        0.7 * virtualBalances.virtualBalanceA + (i * (1.3 * xForPointB - 0.7 * virtualBalances.virtualBalanceA)) / 100;
      const y = invariant / x;

      return { x, y, isSpecialPoint: false };
    });

    return curvePoints;
  }, [currentBalanceA, currentBalanceB, priceRange, virtualBalances, invariant]);

  const specialPoints = useMemo(() => {
    // Add special points
    const pointA = {
      x: virtualBalances.virtualBalanceA,
      y: invariant / virtualBalances.virtualBalanceA,
    };

    const xForPointB = invariant / virtualBalances.virtualBalanceB;
    const pointB = {
      x: xForPointB,
      y: virtualBalances.virtualBalanceB,
    };

    const lowerMarginPoint = {
      x: lowerMargin,
      y: invariant / lowerMargin,
      pointType: 'margin',
    };

    const higherMarginPoint = {
      x: higherMargin,
      y: invariant / higherMargin,
      pointType: 'margin',
    };

    // Add current point
    const currentPoint = {
      x: currentBalanceA + virtualBalances.virtualBalanceA,
      y: currentBalanceB + virtualBalances.virtualBalanceB,
      pointType: 'current',
    };

    return [pointA, pointB, currentPoint, lowerMarginPoint, higherMarginPoint];
  }, [currentBalanceA, currentBalanceB, priceRange, margin, virtualBalances, invariant]);

  useEffect(() => {
    setTimeout(() => {
      initializeVirtualBalances();
    }, 1);
  }, []);

  useEffect(() => {
    let intervalId: NodeJS.Timeout;

    if (isPlaying) {
      intervalId = setInterval(() => {
        setCounter((prev) => prev + speedMultiplier / (1000 / tickMilliseconds));
      }, tickMilliseconds);
    }

    return () => {
      if (intervalId) {
        clearInterval(intervalId);
      }
    };
  }, [isPlaying, speedMultiplier]);

  useEffect(() => {
    if (poolCenteredness > margin / 100) return;
    if (counter % 1 > 0.001 * (tickMilliseconds * speedMultiplier)) return; // Only update once every second.

    // Calculate tau
    const tau = priceShiftDailyRate / 12464935.015039;

    // Determine which token's virtual balance to update based on the condition
    if (
      currentBalanceB === 0 ||
      currentBalanceA / currentBalanceB > virtualBalances.virtualBalanceA / virtualBalances.virtualBalanceB
    ) {
      // Update virtualBalanceB first
      const newVirtualBalanceB = virtualBalances.virtualBalanceB * Math.pow(1 - tau, counter - lastSwapCounter + 1);

      // Then calculate virtualBalanceA based on the new virtualBalanceB
      const newVirtualBalanceA =
        (currentBalanceA * (newVirtualBalanceB + currentBalanceB)) /
        (newVirtualBalanceB * (Math.sqrt(priceRange) - 1) - currentBalanceB);

      setVirtualBalances({
        virtualBalanceA: newVirtualBalanceA,
        virtualBalanceB: newVirtualBalanceB,
      });
    } else {
      // Update virtualBalanceA first
      const newVirtualBalanceA = virtualBalances.virtualBalanceA * Math.pow(1 - tau, counter - lastSwapCounter + 1);

      // Then calculate virtualBalanceB based on the new virtualBalanceA
      const newVirtualBalanceB =
        (currentBalanceB * (newVirtualBalanceA + currentBalanceA)) /
        (newVirtualBalanceA * (Math.sqrt(priceRange) - 1) - currentBalanceA);

      setVirtualBalances({
        virtualBalanceA: newVirtualBalanceA,
        virtualBalanceB: newVirtualBalanceB,
      });
    }
  }, [counter]);

  useEffect(() => {
    if (poolCenteredness <= margin / 100) {
      if (isPoolInRange) {
        setIsPoolInRange(false);
        setOutOfRangeTime(0);
      } else {
        setOutOfRangeTime((prev) => prev + (counter - lastRangeCheckTime));
      }
    } else {
      setIsPoolInRange(true);
    }
    setLastRangeCheckTime(counter);
  }, [counter, poolCenteredness, margin]);

  const handleUpdate = () => {
    setInitialBalanceA(Number(inputBalanceA));
    setInitialBalanceB(Number(inputBalanceB));
    setCurrentBalanceA(Number(inputBalanceA));
    setCurrentBalanceB(Number(inputBalanceB));
    setPriceRange(Number(inputPriceRange));
    setMargin(Number(inputMargin));
    initializeVirtualBalances();
  };

  const initializeVirtualBalances = () => {
    const priceRangeNum = Number(inputPriceRange);
    if (priceRangeNum <= 1) {
      setVirtualBalances({ virtualBalanceA: 0, virtualBalanceB: 0 });
    } else {
      const denominator = Math.sqrt(Math.sqrt(priceRangeNum)) - 1;
      setVirtualBalances({
        virtualBalanceA: Number(inputBalanceA) / denominator,
        virtualBalanceB: Number(inputBalanceB) / denominator,
      });
    }
  };

  const handleSwap = () => {
    const amountIn = Number(swapAmountIn);

    if (poolCenteredness > margin / 100) {
      setLastSwapCounter(counter);
    }

    let newBalanceA: number;
    let newBalanceB: number;
    if (swapTokenIn === 'Token A') {
      // Swapping Token A for Token B
      newBalanceA = currentBalanceA + amountIn;
      newBalanceB = invariant / (newBalanceA + virtualBalances.virtualBalanceA) - virtualBalances.virtualBalanceB;

      if (newBalanceB < 0) {
        newBalanceB = 0;
        newBalanceA = invariant / virtualBalances.virtualBalanceB - virtualBalances.virtualBalanceA;
      }
    } else {
      // Swapping Token B for Token A
      newBalanceB = currentBalanceB + amountIn;
      newBalanceA = invariant / (newBalanceB + virtualBalances.virtualBalanceB) - virtualBalances.virtualBalanceA;

      if (newBalanceA < 0) {
        newBalanceA = 0;
        newBalanceB = invariant / virtualBalances.virtualBalanceA - virtualBalances.virtualBalanceB;
      }
    }

    setCurrentBalanceA(newBalanceA);
    setCurrentBalanceB(newBalanceB);
  };

  const formatTime = (totalSeconds: number) => {
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    return `${hours}:${minutes.toString().padStart(2, '0')}:${seconds.toFixed(0).toString().padStart(2, '0')}`;
  };

  return (
    <Container>
      <Grid container spacing={2}>
        <Grid item xs={3}>
          <Paper style={{ padding: 16 }}>
            <Typography variant="h6">Initial conditions</Typography>
            <TextField
              label="Real Initial Balance A"
              type="number"
              fullWidth
              margin="normal"
              value={inputBalanceA}
              onChange={(e) => setInputBalanceA(Number(e.target.value))}
            />
            <TextField
              label="Real Initial Balance B"
              type="number"
              fullWidth
              margin="normal"
              value={inputBalanceB}
              onChange={(e) => setInputBalanceB(Number(e.target.value))}
            />
            <TextField
              label="Price Range"
              type="number"
              fullWidth
              margin="normal"
              value={inputPriceRange}
              onChange={(e) => setInputPriceRange(Number(e.target.value))}
            />
            <TextField
              label="Margin (%)"
              type="number"
              fullWidth
              margin="normal"
              value={inputMargin}
              onChange={(e) => setInputMargin(Number(e.target.value))}
            />
            <TextField
              label="Price Shift Daily Rate (%)"
              type="number"
              fullWidth
              margin="normal"
              value={priceShiftDailyRate}
              onChange={(e) => setPriceShiftDailyRate(Number(e.target.value))}
            />
            <Button variant="contained" fullWidth onClick={handleUpdate} style={{ marginTop: 16 }}>
              Initialize Pool
            </Button>
          </Paper>

          {/* New Swap Box */}
          <Paper style={{ padding: 16, marginTop: 16 }}>
            <Typography variant="h6">Swap</Typography>
            <TextField
              select
              label="Token In"
              fullWidth
              margin="normal"
              value={swapTokenIn}
              onChange={(e) => setSwapTokenIn(e.target.value)}
              SelectProps={{
                native: true,
              }}
            >
              <option value="Token A">Token A</option>
              <option value="Token B">Token B</option>
            </TextField>
            <TextField
              label="Amount In"
              type="number"
              fullWidth
              margin="normal"
              value={swapAmountIn}
              onChange={(e) => setSwapAmountIn(Number(e.target.value))}
            />
            <Button variant="contained" fullWidth onClick={handleSwap} style={{ marginTop: 16 }}>
              Swap
            </Button>
          </Paper>
        </Grid>

        <Grid item xs={6}>
          <Paper style={{ padding: 16, textAlign: 'center' }}>
            <div style={{ width: '100%', height: 600 }}>
              <D3Chart data={chartData} specialPoints={specialPoints} virtualBalances={virtualBalances} />
            </div>
          </Paper>
          <Paper style={{ padding: 16, marginTop: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 16 }}>
              <Button
                variant="contained"
                onClick={() => setIsPlaying(!isPlaying)}
                startIcon={isPlaying ? <PauseIcon /> : <PlayArrowIcon />}
              >
                {isPlaying ? 'Pause' : 'Play'}
              </Button>
              <Typography
                style={{
                  fontWeight: 'bold',
                  color: isPlaying ? 'green' : 'red',
                }}
              >
                {isPlaying ? 'Running' : 'Paused'} - Simulation time: {formatTime(counter)}
              </Typography>
            </div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {[1, 10, 100, 1000, 10000].map((speed) => (
                <Button
                  key={speed}
                  variant="contained"
                  onClick={() => setSpeedMultiplier(speed)}
                  style={{
                    backgroundColor: speedMultiplier === speed ? '#90caf9' : undefined,
                    flex: '1 1 auto',
                  }}
                >
                  {speed}x
                </Button>
              ))}
            </div>
          </Paper>
        </Grid>

        {/* Current Values Column */}
        <Grid item xs={3}>
          <Paper style={{ padding: 16 }}>
            <Typography variant="h6">Initial Values</Typography>
            <Typography>Initial Balance A: {initialBalanceA.toFixed(2)}</Typography>
            <Typography>Initial Balance B: {initialBalanceB.toFixed(2)}</Typography>
            <Typography>Price Range: {priceRange.toFixed(2)}</Typography>
            <Typography>Margin: {margin.toFixed(2)}%</Typography>

            <Typography variant="h6" style={{ marginTop: 16 }}>
              Token Price
            </Typography>
            <Typography style={{ color: 'red' }}>
              Min Price A: {(Math.pow(virtualBalances.virtualBalanceB, 2) / invariant).toFixed(4)}
            </Typography>
            <Typography style={{ color: 'blue' }}>
              Lower Margin Price A: {(invariant / Math.pow(higherMargin, 2)).toFixed(4)}
            </Typography>
            <Typography style={{ color: 'green' }}>
              Current Price A:{' '}
              {(
                (currentBalanceB + virtualBalances.virtualBalanceB) /
                (currentBalanceA + virtualBalances.virtualBalanceA)
              ).toFixed(4)}
            </Typography>
            <Typography style={{ color: 'blue' }}>
              Higher Margin Price A: {(invariant / Math.pow(lowerMargin, 2)).toFixed(4)}
            </Typography>
            <Typography style={{ color: 'red' }}>
              Max Price A: {(invariant / Math.pow(virtualBalances.virtualBalanceA, 2)).toFixed(4)}
            </Typography>

            <Typography variant="h6" style={{ marginTop: 16 }}>
              Price Range Update
            </Typography>
            <Typography>Pool Centeredness: {poolCenteredness.toFixed(2)}</Typography>
            <Typography>
              Status:{' '}
              <span style={{ color: poolCenteredness > margin / 100 ? 'green' : 'red', fontWeight: 'bold' }}>
                {poolCenteredness > margin / 100 ? 'IN RANGE' : 'OUT OF RANGE'}
              </span>
            </Typography>
            <Typography>Out of Range time: {formatTime(outOfRangeTime)}</Typography>

            <Typography variant="h6" style={{ marginTop: 16 }}>
              Balances
            </Typography>
            <Typography>Invariant: {invariant.toFixed(2)}</Typography>
            <Typography>Current Balance A: {currentBalanceA.toFixed(2)}</Typography>
            <Typography>Current Balance B: {currentBalanceB.toFixed(2)}</Typography>
            <Typography>Virtual Balance A: {virtualBalances.virtualBalanceA.toFixed(2)}</Typography>
            <Typography>Virtual Balance B: {virtualBalances.virtualBalanceB.toFixed(2)}</Typography>
          </Paper>
        </Grid>
      </Grid>
    </Container>
  );
}
