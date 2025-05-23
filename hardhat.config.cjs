// hardhat.config.cjs
const { HardhatUserConfig } = require("hardhat/config");
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const Accounts = [
  process.env.PK_ACCOUNT1,
  process.env.PK_ACCOUNT2,
  process.env.PK_ACCOUNT3,
  process.env.PK_ACCOUNT4,
  process.env.PK_ACCOUNT5,
  process.env.PK_ACCOUNT6,
].filter((account) => account !== undefined);

const config = {
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1_000_000,
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1_000_000,
          },
          viaIR: true,
        },
      },
    ],
  },
  networks: {
    hardhat: {
      gas: "auto",
      blockGasLimit: 0x1fffffffffffff,
      allowUnlimitedContractSize: true,
      accounts: {
        count: 400,
      },
    },
    eth_mainnet: {
      url: process.env.ETH_MAINNET_HTTPS,
      accounts: Accounts,
    },
    arbitrum: {
      url: process.env.ARB_MAINNET_HTTPS,
      accounts: Accounts,
    },
    sepolia: {
      url: process.env.ETH_SEPOLIA_HTTPS,
      accounts: Accounts,
      timeout: 150_000,
    },
    base_sepolia: {
      url: process.env.BASE_SEPOLIA_HTTPS,
      accounts: Accounts,
    },
    base_mainnet: {
      url: process.env.BASE_MAINNET_HTTPS,
      accounts: Accounts,
    },
    sepolia_arb: {
      url: process.env.ARB_SEPOLIA_HTTPS,
      accounts: Accounts,
    },
  },
  mocha: {
    timeout: 1_000_000,
  },
  gasReporter: {
    enabled: true,
    currency: "USD",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};

module.exports = config;
