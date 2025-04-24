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

const optimizerSteps =
  'dhfoDgvulfnTUtnIf [ xa[r]EscLM cCTUtTOntnfDIul Lcul Vcul [j] Tpeul xa[rul] xa[r]cL gvif CTUca[r]LSsTFOtfDnca[r]Iulc ] jmul[jul] VcTOcul jmul : fDnTOcmu';

const overrides = {
  ['contracts/ReClammPool.sol']: {
    version: '0.8.28',
    settings: {
      viaIR: true,
      evmVersion: 'cancun',
      optimizer: {
        enabled: true,
        runs: 1500,
        details: {
          yulDetails: {
            optimizerSteps,
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
