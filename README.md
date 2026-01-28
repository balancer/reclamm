# custom-pool-v3

Example of external custom pool for Balancer V3. Extend it to create new pool types.

# Requirements

- Node.js v18.x (we recommend using nvm to install it)
- Yarn v4.x
- Foundry v1.0.0

# Installation

If it's the first time running the project, run `sh ./scripts/install-fresh.sh` to install the dependencies and build the project. It'll download and compile V3 monorepo, creating node_modules folders in the library (these folders will be needed to use monorepo as a submodule of the custom pool, so tests can use the base test files).

# Testing

After installing the dependencies, run `yarn test` to run forge and hardhat tests.

## Medusa tests

To run medusa tests, you will need [`medusa`](https://github.com/crytic/medusa/tree/master) and [`crytic`](https://github.com/crytic/crytic-compile) installed.

One straightforward, cross platform way of getting it done is using `go` and `pip` installers:
- [Medusa go installation](go install github.com/crytic/medusa@latest): `go install github.com/crytic/medusa@latest`
- [Crytic python installation](https://github.com/crytic/crytic-compile): `pip3 install crytic-compile`

Then, to run the tests, run `yarn test:medusa`.

# Static analysis

To run [Slither](https://github.com/crytic/slither) static analyzer, Python 3.8+ is a requirement.

## Installation in virtual environment

This step will create a Python virtual environment with Slither installed. It only needs to be executed once:

```bash
$ yarn slither-install
```

## Run analyzer

```bash
$ yarn slither
```

The analyzer's global settings can be found in `.slither.config.json`.

Some of the analyzer's known findings are already filtered out using [--triage-mode option](https://github.com/crytic/slither/wiki/Usage#triage-mode); the results of the triage can be found in `slither.db.json` files inside each individual workspace.

To run Slither in triage mode:

```bash
$ yarn slither:triage
```

