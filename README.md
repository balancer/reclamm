# <img src="logo.svg" alt="Balancer" height="128px">

# ReCLAMM Pools

ReClamm (Rebalancing Concentrated Liquidity AMM) pool for Balancer V3.

ReClamm is a two-token pool that operates like a concentrated liquidity AMM with an automatically adjusting price range. When the pool price drifts outside the target
range, the virtual balances shift over time to track the market price, narrowing or widening the price interval as configured. The rate of this shift is controlled by the
`dailyPriceShiftExponent` parameter. The price range itself (i.e., the ratio of the maximum to minimum price) can be updated gradually by the swap fee manager via
`startPriceRatioUpdate`, analogous to the gradual weight change mechanism in Balancer Liquidity Bootstrapping Pools.

Key characteristics:
- Two tokens only; tokens sorted by address at registration
- Invariant: `(Ra + Va)(Rb + Vb)` where `Va`, `Vb` are time-varying virtual balances
- Proportional add/remove liquidity only; unbalanced operations and donations disabled
- The pool contract is its own hook (`onRegister` returns true only for `address(this)`)
- A stateless `ReClammPoolHelper` contract handles initialization math that would otherwise push the pool past the EVM bytecode size limit

## Requirements

- Node.js v24.x (we recommend using nvm to install 24.12.0)
- Yarn v4.x
- Foundry v1.0.0

## Installation

If it's the first time running the project, run `sh ./scripts/install-fresh.sh` to install the dependencies and build the project. It'll download and compile the V3
monorepo, creating `node_modules` folders in the library (these folders are needed so that tests can use the monorepo base test files).

## Testing

After installing the dependencies, run `yarn test` to run forge and hardhat tests.

### Medusa tests

To run medusa tests, you will need [`medusa`](https://github.com/crytic/medusa/tree/master) and [`crytic-compile`](https://github.com/crytic/crytic-compile) installed.

One straightforward, cross-platform way to install them is via `go` and `pip`:

- Medusa: `go install github.com/crytic/medusa@latest`
- crytic-compile: `pip3 install crytic-compile`

Then run: `yarn test:medusa`

## Static analysis

To run [Slither](https://github.com/crytic/slither), Python 3.8+ is required.

### Installation in virtual environment

This step creates a Python virtual environment with Slither installed. Run once:

```bash
yarn slither-install
```

### Run analyzer

```bash
yarn slither
```

Global settings are in `.slither.config.json`. Known findings already filtered via
triage mode are recorded in `slither.db.json`. To run in triage mode:

```bash
yarn slither:triage
```
