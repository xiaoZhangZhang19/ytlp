import { ethers, upgrades } from "hardhat";
import * as fs from "fs";

/**
 * 部署YTLp系统的所有合约（不包含配置）
 */
async function main() {
  console.log("开始部署YT协议可升级合约...\n");
  
  const [deployer] = await ethers.getSigners();
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ==================== 1. 部署代币合约 ====================
  console.log("===== 1. 部署代币合约 =====");
  
  // 部署USDY (可升级)
  console.log("部署USDY...");
  const USDY = await ethers.getContractFactory("USDY");
  const usdy = await upgrades.deployProxy(USDY, [], {
    kind: "uups",
    initializer: "initialize"
  });
  await usdy.waitForDeployment();
  const usdyAddress = await usdy.getAddress();
  console.log("✅ USDY deployed to:", usdyAddress);

  // 部署YTLPToken (可升级)
  console.log("部署YTLPToken...");
  const YTLPToken = await ethers.getContractFactory("YTLPToken");
  const ytLP = await upgrades.deployProxy(YTLPToken, [], {
    kind: "uups",
    initializer: "initialize"
  });
  await ytLP.waitForDeployment();
  const ytLPAddress = await ytLP.getAddress();
  console.log("✅ YTLPToken deployed to:", ytLPAddress);

  // ==================== 2. 部署核心合约 ====================
  console.log("\n===== 2. 部署核心合约 =====");

  // 读取USDC配置
  if (!fs.existsSync("./deployments-usdc-config.json")) {
    throw new Error("未找到 deployments-usdc-config.json，请先运行 01-prepareUSDC.ts");
  }

  const usdcConfig = JSON.parse(fs.readFileSync("./deployments-usdc-config.json", "utf8"));
  const usdcAddress = usdcConfig.contracts.USDC.address;
  const usdcPriceFeedAddress = usdcConfig.contracts.ChainlinkUSDCPriceFeed.address;

  console.log("USDC地址:              ", usdcAddress);
  console.log("Chainlink价格预言机:   ", usdcPriceFeedAddress);
  
  // 部署YTPriceFeed (可升级) - 传入USDC和Chainlink地址
  console.log("\n部署YTPriceFeed...");
  const YTPriceFeed = await ethers.getContractFactory("YTPriceFeed");
  const priceFeed = await upgrades.deployProxy(
    YTPriceFeed, 
    [usdcAddress, usdcPriceFeedAddress],  // 传入两个参数
    {
      kind: "uups",
      initializer: "initialize"
    }
  );
  await priceFeed.waitForDeployment();
  const priceFeedAddress = await priceFeed.getAddress();
  console.log("✅ YTPriceFeed deployed to:", priceFeedAddress);

  // 部署YTVault (可升级)
  console.log("部署YTVault...");
  const YTVault = await ethers.getContractFactory("YTVault");
  const vault = await upgrades.deployProxy(
    YTVault,
    [usdyAddress, priceFeedAddress],
    {
      kind: "uups",
      initializer: "initialize"
    }
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log("✅ YTVault deployed to:", vaultAddress);

  // 部署YTPoolManager (可升级)
  console.log("部署YTPoolManager...");
  const YTPoolManager = await ethers.getContractFactory("YTPoolManager");
  const cooldownDuration = 15 * 60; // 15分钟
  const poolManager = await upgrades.deployProxy(
    YTPoolManager,
    [vaultAddress, usdyAddress, ytLPAddress, cooldownDuration],
    {
      kind: "uups",
      initializer: "initialize"
    }
  );
  await poolManager.waitForDeployment();
  const poolManagerAddress = await poolManager.getAddress();
  console.log("✅ YTPoolManager deployed to:", poolManagerAddress);

  // 部署YTRewardRouter (可升级)
  console.log("部署YTRewardRouter...");
  const YTRewardRouter = await ethers.getContractFactory("YTRewardRouter");
  const router = await upgrades.deployProxy(
    YTRewardRouter,
    [usdyAddress, ytLPAddress, poolManagerAddress, vaultAddress],
    {
      kind: "uups",
      initializer: "initialize"
    }
  );
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("✅ YTRewardRouter deployed to:", routerAddress);

  // ==================== 3. 输出部署信息 ====================
  console.log("\n===== 部署完成！=====");
  console.log("\n📋 合约地址:");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("USDY:            ", usdyAddress);
  console.log("YTLPToken:       ", ytLPAddress);
  console.log("YTPriceFeed:     ", priceFeedAddress);
  console.log("YTVault:         ", vaultAddress);
  console.log("YTPoolManager:   ", poolManagerAddress);
  console.log("YTRewardRouter:  ", routerAddress);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // 获取实现合约地址
  console.log("\n📋 实现合约地址 (用于验证和升级):");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  const usdyImpl = await upgrades.erc1967.getImplementationAddress(usdyAddress);
  const ytLPImpl = await upgrades.erc1967.getImplementationAddress(ytLPAddress);
  const priceFeedImpl = await upgrades.erc1967.getImplementationAddress(priceFeedAddress);
  const vaultImpl = await upgrades.erc1967.getImplementationAddress(vaultAddress);
  const poolManagerImpl = await upgrades.erc1967.getImplementationAddress(poolManagerAddress);
  const routerImpl = await upgrades.erc1967.getImplementationAddress(routerAddress);
  
  console.log("USDY Implementation:            ", usdyImpl);
  console.log("YTLPToken Implementation:       ", ytLPImpl);
  console.log("YTPriceFeed Implementation:     ", priceFeedImpl);
  console.log("YTVault Implementation:         ", vaultImpl);
  console.log("YTPoolManager Implementation:   ", poolManagerImpl);
  console.log("YTRewardRouter Implementation:  ", routerImpl);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // 保存到JSON文件
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      USDY: {
        proxy: usdyAddress,
        implementation: usdyImpl
      },
      YTLPToken: {
        proxy: ytLPAddress,
        implementation: ytLPImpl
      },
      YTPriceFeed: {
        proxy: priceFeedAddress,
        implementation: priceFeedImpl
      },
      YTVault: {
        proxy: vaultAddress,
        implementation: vaultImpl
      },
      YTPoolManager: {
        proxy: poolManagerAddress,
        implementation: poolManagerImpl
      },
      YTRewardRouter: {
        proxy: routerAddress,
        implementation: routerImpl
      }
    }
  };

  fs.writeFileSync(
    "./deployments-ytlp.json",
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("\n✅ 部署信息已保存到 deployments-ytlp.json");
  console.log("\n⚠️  注意: 合约已部署但未配置，请运行 configureYTLp.ts 进行配置");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
