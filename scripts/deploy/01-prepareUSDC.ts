import { ethers } from "hardhat";
import * as fs from "fs";

/**
 * 准备USDC和Chainlink配置
 * USDC是已存在的代币，无需部署
 */
async function main() {
  console.log("准备USDC和Chainlink配置...\n");

  const [deployer] = await ethers.getSigners();
  console.log("操作账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // 获取当前网络
  const network = await ethers.provider.getNetwork();
  const chainId = network.chainId;
  
  console.log("网络:", network.name);
  console.log("Chain ID:", chainId.toString());

  // ===== 根据网络配置USDC和Chainlink地址 =====
  let usdcAddress: string;
  let usdcPriceFeedAddress: string;
  
  if (chainId === 56n) {
    // BSC 主网
    console.log("\n检测到 BSC 主网");
    usdcAddress = "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d";
    usdcPriceFeedAddress = "0x51597f405303C4377E36123cBc172b13269EA163";
    console.log("✅ USDC地址 (BSC):", usdcAddress);
    console.log("✅ Chainlink USDC/USD (BSC):", usdcPriceFeedAddress);
  } else if (chainId === 421614n) {
    // Arbitrum 测试网
    console.log("\n检测到 Arbitrum 测试网");
    usdcAddress = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
    usdcPriceFeedAddress = "0x0153002d20B96532C639313c2d54c3dA09109309";
    console.log("✅ USDC地址 (Arbitrum):", usdcAddress);
    console.log("✅ Chainlink USDC/USD (Arbitrum):", usdcPriceFeedAddress);
  } else if (chainId === 97n) {
    // BNB 测试网
    console.log("\n检测到 BNB 测试网");
    usdcAddress = "0x939cf46F7A4d05da2a37213E7379a8b04528F590";
    usdcPriceFeedAddress = "0x90c069C4538adAc136E051052E14c1cD799C41B7";
    console.log("✅ USDC地址 (BSC Testnet):", usdcAddress);
    console.log("✅ Chainlink USDC/USD (BSC Testnet):", usdcPriceFeedAddress);
  } else {
    throw new Error(`不支持的网络: ${chainId}`);
  }

  // ===== 验证合约是否存在 =====
  console.log("\n===== 验证合约 =====");
  
  if (usdcAddress !== "0x0000000000000000000000000000000000000000") {
    const usdcCode = await ethers.provider.getCode(usdcAddress);
    if (usdcCode === "0x") {
      console.log("❌ USDC合约不存在于该地址");
    } else {
      console.log("✅ USDC合约验证通过");
      
      // 尝试读取USDC信息
      try {
        const usdc = await ethers.getContractAt(
          ["function name() view returns (string)", "function symbol() view returns (string)", "function decimals() view returns (uint8)"],
          usdcAddress
        );
        const name = await usdc.name();
        const symbol = await usdc.symbol();
        const decimals = await usdc.decimals();
        
        console.log("  名称:", name);
        console.log("  符号:", symbol);
        console.log("  精度:", decimals.toString());
      } catch (e) {
        console.log("  ⚠️  无法读取USDC信息（可能是接口不匹配）");
      }
    }
  }

  if (usdcPriceFeedAddress !== "0x0000000000000000000000000000000000000000") {
    const priceFeedCode = await ethers.provider.getCode(usdcPriceFeedAddress);
    if (priceFeedCode === "0x") {
      console.log("❌ Chainlink价格预言机不存在于该地址");
    } else {
      console.log("✅ Chainlink价格预言机验证通过");
      
      // 尝试读取最新价格
      try {
        const priceFeed = await ethers.getContractAt(
          ["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)"],
          usdcPriceFeedAddress
        );
        const [, price] = await priceFeed.latestRoundData();
        console.log("  当前USDC价格:", ethers.formatUnits(price, 8), "USD (精度1e8)");
      } catch (e) {
        console.log("  ⚠️  无法读取价格数据");
      }
    }
  }

  // ===== 保存配置 =====
  const configInfo = {
    network: network.name,
    chainId: chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      USDC: {
        address: usdcAddress,
        description: "USDC代币地址（已存在的合约）"
      },
      ChainlinkUSDCPriceFeed: {
        address: usdcPriceFeedAddress,
        description: "Chainlink USDC/USD 价格预言机",
        precision: "1e8"
      }
    },
    notes: {
      bsc: "BSC主网的USDC是18位精度",
      arbSepolia: "Arbitrum Sepolia的USDC是6位精度",
    }
  };

  fs.writeFileSync(
    "./deployments-usdc-config.json",
    JSON.stringify(configInfo, null, 2)
  );

  // ===== 显示摘要 =====
  console.log("\n===== 配置摘要 =====");
  console.log("USDC地址:              ", usdcAddress);
  console.log("Chainlink价格预言机:   ", usdcPriceFeedAddress);
  console.log("\n✅ 配置已保存到 deployments-usdc-config.json");

  console.log("\n💡 下一步:");
  console.log("1. 运行 02-deployYTLp.ts 部署YTLp系统");
  console.log("2. 运行 03-deployAsset.ts 部署YTAssetFactory系统");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

