import { HardhatUserConfig } from 'hardhat/config';
import { name } from './package.json';

import * as hardhatBaseConfig from './lib/balancer-v3-monorepo/pvt/common/hardhat-base-config';
import { warnings } from './lib/balancer-v3-monorepo/pvt/common/hardhat-base-config';

import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-ethers';
import '@typechain/hardhat';

import 'hardhat-ignore-warnings';
import 'hardhat-gas-reporter';
import 'hardhat-contract-sizer';

const overrides = {
  ['contracts/ReClammPool.sol']: {
    version: '0.8.27',
    settings: {
      viaIR: true,
      evmVersion: 'cancun',
      optimizer: {
        enabled: true,
        runs: 700,
        details: {
          yulDetails: {
            optimizerSteps: hardhatBaseConfig.DEFAULT_OPTIMIZER_STEPS,
          },
        },
      },
    },
  },
  ['contracts/ReClammPoolFactory.sol']: {
    version: '0.8.27',
    settings: {
      viaIR: true,
      evmVersion: 'cancun',
      optimizer: {
        enabled: true,
        runs: 700,
        details: {
          yulDetails: {
            optimizerSteps: hardhatBaseConfig.DEFAULT_OPTIMIZER_STEPS,
          },
        },
      },
    },
  },
};

const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  solidity: {
    compilers: hardhatBaseConfig.compilers,
    overrides,
  },
  warnings,
};

export default config;
