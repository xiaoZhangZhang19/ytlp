# Hardhat2 + Foundry EVM 开发框架

这是一个将 Hardhat 与 Foundry 无缝整合的 Solidity 开发框架，既保留了 Hardhat 的插件生态（部署、验证、脚本执行、TypeScript 开发体验），也利用 Foundry 的高速 EVM、测试与脚本执行能力。适用于复杂合约开发、测试驱动开发 (TDD)、多环境部署与高级调试需求。

## create2 factory
框架通过魔改 hardhdat-upgrade 包实现可以指定各条链的factory合约地址使用create2部署地址一样的合约。
注意：调用factory部署合约时需要确定你的地址拥有factory合约的admin权限，否则会失败。

可升级合约使用方式（想要使用factory部署，在调用upgrades.deployProxy时指定create2Factory配置即可。否则不指定create2Factory配置就是非create2 factory模式进行部署）：
```bash
const ContractFactory = await ethers.getContractFactory(CONTRACT_NAME);
const INIT_ARGS: any[] = [];

const create2Config = {
    address: FACTORY_ADDRESS,
    salt: proxySalt,          // 代理合约的 salt
    implSalt: implSalt,       // 实现合约的 salt
    deployImpl: true,         // 实现合约也用 CREATE2 部署
  };
  
  const contract = await upgrades.deployProxy(
    ContractFactory,
    INIT_ARGS,
    {
      initializer: 'initialize',
      kind: 'uups',
      ...( { create2Factory: create2Config } as any ),
    }
  );
```

不可升级合约使用方式（不想使用factory部署，直接调用Yourcontract.deploy即可）：
```bash
const ContractFactory = await ethers.getContractFactory('YourContract');
const bytecode = ContractFactory.bytecode;
const constructorArgs = ethers.AbiCoder.defaultAbiCoder().encode(
  ['uint256'], // 构造函数参数类型
  [123]        // 构造函数参数值
);

const initCode = ethers.concat([bytecode, constructorArgs]);

const factoryContract = await ethers.getContractAt(
  ['function deploy(bytes32 salt, bytes memory initCode, bytes memory data, uint256 create2ForwardValue, uint256 callForwardValue) external payable returns (address)'],
  FACTORY_ADDRESS
);

const tx = await factoryContract.deploy(
  salt,
  initCode,
  '0x',  // 部署后不需要额外调用
  0,     // create2ForwardValue
  0      // callForwardValue
);
```


同时本项目集成了 check / sync / validate / parse 四个核心命令，构建出一套完整的智能合约升级与安全验证流程。
额外带有修复hardhat-config.ts文件引用错误的功能 fix（使用evm-hardhat-foundry包部署的框架则不会用到此功能,以往项目可能会用到,例如错误引用：import { HardhatUserConfig } from "hardhat/config";）

## 功能特性
功能一： 字节码检查（check）
功能二： 合约状态同步（sync）
功能三： 升级验证（validate）
功能四： Calldata解析（parse）
功能五： hardhat-config.ts文件修复（fix）

### 功能一： 字节码检查（check）
- ✅ 检查链下合约代码和链上合约代码是否一致
- ✅ 支持检查单个合约、指定网络或所有合约
- ✅ 智能识别 Constructor 参数差异和 Immutable 变量差异
- ✅ 自动移除元数据进行比较
- ✅ 生成详细的 JSON 报告
- ✅ 支持增量更新报告

#### 1. 修改配置文件

在项目根目录创建 `contractInfo.json` 文件：

```json
{
  "eth": {
    "Vault": "0x80aaf2e4636c510e067a5d300d8bafd48027addf",
    "VaultCrossChainRelay": "0x060194eec4556096baaabd6bf553d2658d6a66ab"
  },
  "bsc": {
    "Vault": "0x2cb7d2603a5f43b9fe79e98f09fe3eec40b6765d",
    "VaultCrossChainRelay": "0x23ae3a565e0896866e7725fe6d49fd777359c162"
  }
}
```

格式说明：
- 第一层 key 是网络名称（必须与 `hardhat.config.js` 中的网络名称一致）
- 第二层 key 是合约名称（必须与编译的合约名称一致）
- value 是合约地址

#### 2. 配置 Hardhat

确保 `hardhat.config.js` 中配置了相应的网络：

```javascript
module.exports = {
  networks: {
    eth: {
      url: "https://eth-mainnet.g.alchemy.com/v2/YOUR-API-KEY",
    },
    bsc: {
      url: "https://bsc-dataseed.binance.org/",
    }
  }
};
```

#### 3. 使用工具

##### 📋 查看帮助

```bash
npx gate-tool --help
```

##### 🔍 字节码检查

```bash
# 检查所有合约（推荐）
npx gate-tool check

# 检查指定合约
npx gate-tool check --contract Vault

# 检查指定网络
npx gate-tool check --network eth

# 指定配置文件路径
npx gate-tool check --config ./config/contracts.json

# 指定输出报告路径
npx gate-tool check --output ./reports/result.json
```

### 功能二： 合约状态同步（sync）
- ✅ 同步链上合约状态到本地 .openzeppelin 文件
- ✅ 自动读取链上实现合约地址
- ✅ 获取并更新存储布局信息

#### 1. 同步链上合约状态

当合约通过 calldata 方式由其他人（如多签钱包）执行升级后，本地的 `.openzeppelin` 文件不会自动更新。使用此命令可以从链上读取最新状态并更新本地文件。

```bash
# 同步合约状态（推荐）
npx gate-tool sync \
  --proxy 0x1234... \
  --contract CounterUUPS \
  --network sepolia
```

### 功能三： 升级验证（validate）
- ✅ 验证合约升级的安全性
- ✅ 检查存储布局兼容性
- ✅ 自动部署新实现合约
- ✅ 生成 upgradeToAndCall 的 calldata
- ✅ 支持同一合约和不同合约的升级模式

#### 1. 验证升级安全性并生成 calldata

验证合约升级的安全性，并生成 `upgradeToAndCall` 的 calldata。

```bash
# 不同合约升级（从 CounterUUPS 升级到 CounterUUPSV2）
npx gate-tool validate \
  --proxy 0x1234... \
  --old CounterUUPS \
  --new CounterUUPSV2 \
  --network sepolia

# 同一合约升级（修改现有合约后升级）（推荐）
npx gate-tool validate \
  --proxy 0x1234... \
  --old CounterUUPS \
  --new CounterUUPS \
  --network sepolia

# 指定输出文件路径
npx gate-tool validate \
  --proxy 0x1234... \
  --old CounterUUPS \
  --new CounterUUPSV2 \
  --network sepolia \
  --output ./upgrade-info.json
```

**注意：** `validate` 命令会在链上部署新的实现合约（仅用于验证），但不会升级代理合约。请使用生成的 calldata 通过多签钱包执行升级。

### 功能四： Calldata 解析（parse）
- ✅ 解析 EVM calldata，显示函数名称和参数
- ✅ 支持从 Hardhat artifacts 自动查找 ABI
- ✅ 支持指定自定义 ABI 文件路径
- ✅ 支持直接提供 ABI 数组
- ✅ 支持批量解析多个 calldata
- ✅ 友好的彩色输出和 JSON 导出

#### 1. 解析 Calldata

解析 EVM calldata，将其转换为人类可读的函数调用信息。

```bash
# 从 JSON 文件单个或批量读取（推荐）
npx gate-tool parse --input parseCalldata.example.json --output results.json

# 直接从命令行参数（使用合约名称从 artifacts 查找 ABI）
npx gate-tool parse \
  --to 0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  --contract Counter \
  --calldata 0x3fb5c1cb0000000000000000000000000000000000000000000000000000000000000064

# 使用自定义 ABI 文件
npx gate-tool parse \
  --to 0x1234... \
  --abi-path ./custom-abi/MyContract.json \
  --calldata 0x...

**输入文件格式示例：**

```json
{
  "to": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  "contractName": "Counter",
  "calldata": "0x3fb5c1cb0000000000000000000000000000000000000000000000000000000000000064"
}
```

**批量解析格式（数组 包含三种形式）：**

```json
[
  {
    "to": "0x...",
    "contractName": "Counter",
    "calldata": "0x..."
  },
  {
    "to": "0x...",
    "abiPath": "./abi.json",
    "calldata": "0x..."
  },
  {
    "": "0x...",
    "abi": [
      {
        "inputs": [
          {"name": "spender", "type": "address"},
          {"name": "amount", "type": "uint256"}
        ],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "nonpayable",
        "type": "function"
      }
    ],
    "calldata": "0x..."
  }
]
```

支持三种 ABI 来源方式：
1. **contractName** - 从 Hardhat artifacts 自动查找（需要先编译合约）
2. **abiPath** - 指定 ABI 文件路径
3. **abi** - 直接在 JSON 中提供 ABI 数组

### 功能五： 配置修复（fix）
- ✅ 自动检测 Hardhat 配置文件的兼容性问题
- ✅ 智能修复 ESM 模块导入错误
- ✅ 交互式确认修复操作
- ✅ 自动备份原配置文件
- ✅ 支持仅检查模式

#### 1. 配置修复（推荐首次使用）

如果在使用过程中遇到 Hardhat 配置导入错误，可以使用 `fix` 命令自动修复：

```bash
# 自动检测并修复配置问题（推荐 交互式）
npx gate-tool fix

# 仅检查问题，不执行修复
npx gate-tool fix --check

# 跳过确认，直接修复
npx gate-tool fix --yes
```

**常见问题：**
- `Cannot find module 'hardhat/config'` - 导入语句需要使用 `type` 关键字
- `Did you mean to import "hardhat/config.js"?` - ESM 模块兼容性问题

`fix` 命令会自动将：
```typescript
import { HardhatUserConfig } from "hardhat/config";
```
修复为：
```typescript
import type { HardhatUserConfig } from "hardhat/config";
```

## 命令选项

### check 命令

| 选项 | 简写 | 说明 | 默认值 |
|------|------|------|--------|
| `--contract <name>` | `-c` | 指定要检查的合约名称 | - |
| `--network <name>` | `-n` | 指定要检查的网络名称 | - |
| `--config <path>` | - | 指定配置文件路径 | `./contractInfo.json` |
| `--output <path>` | `-o` | 指定输出报告文件路径 | `./bytecode-check-report.json` |

### sync 命令

| 选项 | 简写 | 说明 | 必需 |
|------|------|------|------|
| `--proxy <address>` | - | 代理合约地址 | ✅ |
| `--contract <name>` | - | 合约名称 | ✅ |
| `--network <name>` | `-n` | 网络名称 | - |

### validate 命令

| 选项 | 简写 | 说明 | 必需 |
|------|------|------|------|
| `--proxy <address>` | - | 代理合约地址 | ✅ |
| `--old <name>` | - | 旧合约名称 | ✅ |
| `--new <name>` | - | 新合约名称 | ✅ |
| `--network <name>` | `-n` | 网络名称 | - |
| `--output <path>` | `-o` | 输出文件路径 | `./upgradeCalldata.json` |

#### parse 命令

| 选项 | 简写 | 说明 | 默认值 |
|------|------|------|--------|
| `--input <path>` | `-i` | 输入 JSON 文件路径 | - |
| `--to <address>` | - | 目标合约地址（命令行模式） | - |
| `--calldata <data>` | - | Calldata 十六进制数据（命令行模式） | - |
| `--contract <name>` | `-c` | 合约名称（从 artifacts 查找 ABI） | - |
| `--abi-path <path>` | - | 自定义 ABI 文件路径 | - |
| `--output <path>` | `-o` | 输出 JSON 文件路径 | - |
**ABI 来源优先级**：直接提供的 abi > abiPath > contractName