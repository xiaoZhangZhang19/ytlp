import "@nomicfoundation/hardhat-foundry";
import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-solc";
import "hardhat-abi-exporter";
import * as dotenv from "dotenv";
dotenv.config();
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";

const accounts =
  process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [];

const config: HardhatUserConfig = {
  // 编译配置
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      outputSelection: {
        '*': {
          '*': [
            'abi',
            'evm.bytecode',
            'evm.deployedBytecode',
            'evm.methodIdentifiers',
            'metadata',
            'storageLayout'  // 用于升级验证
          ],
          '': ['ast']  // 源代码 AST
        },
      },
    },
  },

  zksolc: {
    version: "1.3.22",
    compilerSource: "binary",
    settings: {
        isSystem: false, // optional.  Enables Yul instructions available only for zkSync system contracts and libraries
        forceEvmla: false, // optional. Falls back to EVM legacy assembly if there is a bug with Yul
        optimizer: {
          enabled: true, // optional. True by default
          mode: 'z' // optional. 3 by default, z to optimize bytecode size
        },
      },
  },

  // 设置单个测试用例的最大执行时间
  mocha: {
    timeout: 10 * 60 * 1000,
  },

  // 网络配置
  networks: {
    hardhat: {
      allowUnlimitedContractSize: false,
      chainId: 1,
    },
    localhost:{
         url:"http://127.0.0.1:8545",
         accounts:accounts,
    },
    eth: {
      url: "https://ethereum-rpc.publicnode.com",
      accounts: accounts,
      chainId: 1,
      },
    op: {
      url: "https://optimism-rpc.publicnode.com",
      accounts: accounts,
      chainId: 10,
    },
    bsc: {
      url:"https://bsc.drpc.org",
      accounts: accounts,
      chainId: 56,
    },
    wld: {
      url: "https://480.rpc.thirdweb.com",
      accounts: accounts,
      chainId: 480,
    },
    polygon: {
      url:"https://polygon.drpc.org",
      accounts: accounts,
      chainId: 137,
    },
    ftm: {
      url: "https://fantom-json-rpc.stakely.io",
      accounts: accounts,
      chainId: 250,
    },
    zk: {
      url: "https://mainnet.era.zksync.io",
      accounts: accounts,
      ethNetwork: "mainnet",
      zksync: true,
      chainId: 324,
    },
    linea: { 
      url: "https://linea.drpc.org",
      accounts: accounts,
      chainId: 59144,
    },
    base: {
      url: "https://base.drpc.org",
      accounts: accounts,
      chainId: 8453,
    },
    arb: {
      url: "https://public-arb-mainnet.fastnode.io",
      accounts: accounts,
      chainId: 42161,
    },
    blast: {
      url: "https://blast.drpc.org",
      accounts: accounts,
      chainId: 81457,
    },
    avax: {
      url:"https://endpoints.omniatech.io/v1/avax/mainnet/public",
      accounts: accounts,
      chainId: 43114,
    },
    gateLayer: {
      url: "https://gatelayer-mainnet.gatenode.cc",
      accounts: accounts,
      chainId: 10088,
    },
    baseSepolia: {
      url: "https://base-sepolia.drpc.org",
      accounts: accounts,
      chainId: 84532,
    },
    arbSepolia: {
      url: "https://arbitrum-sepolia.gateway.tenderly.co",
      accounts: accounts,
      chainId: 421614,
    },
    bscTestnet: {
      url: "https://api.zan.top/node/v1/bsc/testnet/baf84c429d284bb5b676cb8c9ca21c07",
      accounts: accounts,
      chainId: 97,
      gasPrice: 2000000000,
    },
  },

  // gas报告配置
  gasReporter: {
    currency: "USDT",
    enabled: !!process.env.REPORT_GAS,
  },

  // 合约大小报告配置
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: false,
    only: [],
  },

  // ABI导出配置
  abiExporter: {
    path: "./abis",
    runOnCompile: true,
    clear: true,
    flat: true,
    pretty: false,
    except: ["lib"],
  },

  // 合约验证配置 (Etherscan V2 API)
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY as string,
    customChains: [
      {
        network: "arbSepolia",
        chainId: 421614,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io"
        }
      },
      {
        network: "arb",
        chainId: 42161,
        urls: {
          apiURL: "https://api.arbiscan.io/api",
          browserURL: "https://arbiscan.io"
        }
      },
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org"
        }
      },
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org"
        }
      },
      {
        network: "op",
        chainId: 10,
        urls: {
          apiURL: "https://api-optimistic.etherscan.io/api",
          browserURL: "https://optimistic.etherscan.io"
        }
      },
      {
        network: "polygon",
        chainId: 137,
        urls: {
          apiURL: "https://api.polygonscan.com/api",
          browserURL: "https://polygonscan.com"
        }
      },
      {
        network: "bsc",
        chainId: 56,
        urls: {
          apiURL: "https://api.bscscan.com/api",
          browserURL: "https://bscscan.com"
        }
      },
      {
        network: "ftm",
        chainId: 250,
        urls: {
          apiURL: "https://api.ftmscan.com/api",
          browserURL: "https://ftmscan.com"
        }
      },
      {
        network: "avax",
        chainId: 43114,
        urls: {
          apiURL: "https://api.snowtrace.io/api",
          browserURL: "https://snowtrace.io"
        }
      },
      {
        network: "linea",
        chainId: 59144,
        urls: {
          apiURL: "https://api.lineascan.build/api",
          browserURL: "https://lineascan.build"
        }
      }
    ]
  },
  
  // Sourcify 验证配置（可选）
  sourcify: {
    enabled: false  // 设置为 true 可启用 Sourcify 验证
  },

  // 覆盖配置
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },

  // typechain配置
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
};

export default config;
