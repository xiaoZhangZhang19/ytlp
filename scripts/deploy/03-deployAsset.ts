import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
/**
 * 部署YTAssetFactory和YTAssetVault系统
 */
async function main() {
  console.log("开始部署YT Asset Vault系统...\n");

  const [deployer] = await ethers.getSigners();
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // 读取USDC配置
  if (!fs.existsSync("./deployments-usdc-config.json")) {
    throw new Error("未找到 deployments-usdc-config.json，请先运行 01-prepareUSDC.ts");
  }

  const usdcConfig = JSON.parse(fs.readFileSync("./deployments-usdc-config.json", "utf8"));
  const USDC_ADDRESS = usdcConfig.contracts.USDC.address;
  const USDC_PRICE_FEED_ADDRESS = usdcConfig.contracts.ChainlinkUSDCPriceFeed.address;
  
  // ===== 1. 部署YTAssetVault实现合约 =====
  console.log("===== 1. 部署YTAssetVault实现合约 =====");
  const YTAssetVault = await ethers.getContractFactory("YTAssetVault");
  console.log("部署YTAssetVault实现...");
  const vaultImpl = await YTAssetVault.deploy();
  await vaultImpl.waitForDeployment();
  const vaultImplAddress = await vaultImpl.getAddress();
  console.log("✅ YTAssetVault实现部署到:", vaultImplAddress);

  // ===== 2. 部署YTAssetFactory（可升级） =====
  console.log("\n===== 2. 部署YTAssetFactory（可升级） =====");
  const YTAssetFactory = await ethers.getContractFactory("YTAssetFactory");
  
  // 默认硬顶: 1000万 
  const defaultHardCap = ethers.parseEther("10000000");
  
  console.log("部署YTAssetFactory代理...");
  const vaultFactory = await upgrades.deployProxy(
    YTAssetFactory,
    [vaultImplAddress, defaultHardCap],
    {
      initializer: "initialize",
      kind: "uups",
    }
  );
  await vaultFactory.waitForDeployment();
  const vaultFactoryAddress = await vaultFactory.getAddress();
  console.log("✅ YTAssetFactory部署到:", vaultFactoryAddress);

  const vaultFactoryImplAddress = await upgrades.erc1967.getImplementationAddress(vaultFactoryAddress);
  console.log("✅ YTAssetFactory实现:", vaultFactoryImplAddress);

  // ===== 3. 显示部署摘要 =====
  console.log("\n===== 部署摘要 =====");
  console.log("USDC地址:              ", USDC_ADDRESS);
  console.log("Chainlink价格预言机:   ", USDC_PRICE_FEED_ADDRESS);
  console.log("YTAssetVault实现:      ", vaultImplAddress);
  console.log("YTAssetFactory代理:    ", vaultFactoryAddress);
  console.log("YTAssetFactory实现:    ", vaultFactoryImplAddress);
  console.log("默认硬顶:              ", ethers.formatEther(defaultHardCap), "tokens");

  // 保存到JSON文件
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    usdcAddress: USDC_ADDRESS,
    usdcPriceFeedAddress: USDC_PRICE_FEED_ADDRESS,
    defaultHardCap: defaultHardCap.toString(),
    contracts: {
      YTAssetVault: {
        implementation: vaultImplAddress
      },
      YTAssetFactory: {
        proxy: vaultFactoryAddress,
        implementation: vaultFactoryImplAddress
      }
    },
    vaults: [] // 创建的vault将被添加到这里
  };

  fs.writeFileSync( 
    "./deployments-vault-system.json",
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("\n✅ 部署信息已保存到 deployments-vault-system.json");

  console.log("\n💡 下一步:");
  console.log("1. 使用 createVault.ts 创建YTAssetVault代币");
  console.log("2. 在YTLp系统中将创建的vault添加到白名单");
  console.log("3. 为vault设置价格和其他参数");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
