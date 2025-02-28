# custom-pool-v3

Example of external custom pool for Balancer V3. Extend it to create new pool types.

# Requirements

- Node.js v18.x (we recommend using nvm to install it)
- Yarn v4.x
- Foundry v1.0.0

# Installation

If it's the first time running the project, run `yarn install-fresh` to install the dependencies and build the project. It'll download and compile V3 monorepo, creating node_modules folders in the library (these folders will be needed to use monorepo as a submodule of the custom pool, so tests can use the base test files).

# Testing

After installing the dependencies, run `yarn test` to run forge and hardhat tests.
