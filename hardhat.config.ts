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

const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  solidity: {
    compilers: hardhatBaseConfig.compilers,
    overrides: { ...hardhatBaseConfig.overrides(name) },
  },
  warnings,
};

export default config;
