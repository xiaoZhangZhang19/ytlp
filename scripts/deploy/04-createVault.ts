import { ethers } from "hardhat";
import * as fs from "fs";

/**
 * 通过YTAssetFactory创建YTAssetVault
 */
async function main() {
  console.log("开始创建YTAssetVault...\n");

  const [deployer] = await ethers.getSigners();
  console.log("操作账户:", deployer.address);

  // ==================== 1. 读取Factory地址 ====================
  console.log("\n===== 1. 读取Factory地址 =====");
  
  if (!fs.existsSync("./deployments-vault-system.json")) {
    throw new Error("未找到 deployments-vault-system.json，请先运行 deployAsset.ts");
  }

  const vaultDeployment = JSON.parse(fs.readFileSync("./deployments-vault-system.json", "utf8"));
  const factoryAddress = vaultDeployment.contracts.YTAssetFactory.proxy;
  const usdcAddress = vaultDeployment.usdcAddress;
  const usdcPriceFeedAddress = vaultDeployment.usdcPriceFeedAddress;
  
  console.log("YTAssetFactory:        ", factoryAddress);
  console.log("USDC地址:              ", usdcAddress);
  console.log("Chainlink价格预言机:   ", usdcPriceFeedAddress);

  const factory = await ethers.getContractAt("YTAssetFactory", factoryAddress);

  // 注意：YTAssetVault的价格精度是1e30
  const PRICE_PRECISION = ethers.parseUnits("1", 30); // 1e30

  // 可以在这里修改要创建的vault参数
  const vaultParams = [
    {
      name: "YT Token A",
      symbol: "YT-A",
      manager: deployer.address,
      hardCap: ethers.parseEther("10000000"), // 1000万
      redemptionTime: Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60, // 1年后
      initialYtPrice: PRICE_PRECISION      // $1.00 (精度1e30)
    },
    {
      name: "YT Token B",
      symbol: "YT-B",
      manager: deployer.address,
      hardCap: ethers.parseEther("10000000"),
      redemptionTime: Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60,
      initialYtPrice: PRICE_PRECISION      // $1.00 (精度1e30)
    },
    {
      name: "YT Token C",
      symbol: "YT-C",
      manager: deployer.address,
      hardCap: ethers.parseEther("10000000"),
      redemptionTime: Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60,
      initialYtPrice: PRICE_PRECISION      // $1.00 (精度1e30)
    }
  ];

  // ==================== 2. 创建Vaults ====================
  console.log("\n===== 2. 创建Vaults =====");

  const createdVaults: any[] = [];

  for (const params of vaultParams) {
    console.log(`\n创建 ${params.name} (${params.symbol})...`);
    
    // 价格已经是1e30精度，直接使用
    const ytPrice = params.initialYtPrice;

    // 新的createVault签名：
    // createVault(name, symbol, manager, hardCap, usdc, redemptionTime, ytPrice, usdcPriceFeed)
    const tx = await factory.createVault(
      params.name,
      params.symbol,
      params.manager,
      params.hardCap,
      usdcAddress,               // USDC地址
      params.redemptionTime,
      ytPrice,                   // 只需要ytPrice
      usdcPriceFeedAddress       // Chainlink价格预言机地址
    );

    const receipt = await tx.wait();
    
    // 从事件中获取vault地址
    const event = receipt?.logs.find((log: any) => {
      try {
        const parsed = factory.interface.parseLog({
          topics: log.topics as string[],
          data: log.data
        });
        return parsed?.name === "VaultCreated";
      } catch {
        return false;
      }
    });

    if (event) {
      const parsed = factory.interface.parseLog({
        topics: event.topics as string[],
        data: event.data
      });
      const vaultAddress = parsed?.args[0];
      const index = parsed?.args[5];

      console.log("  ✅ Vault地址:", vaultAddress);
      console.log("  ✅ Vault索引:", index.toString());
      
      // 配置价格过期阈值
      const vault = await ethers.getContractAt("YTAssetVault", vaultAddress);
      const network = await ethers.provider.getNetwork();
      const isTestnet = network.chainId === 97n || network.chainId === 11155111n; // BSC测试网或Sepolia
      const priceStalenesThreshold = isTestnet ? 86400 : 3600; // 测试网24小时，主网1小时
      
      await factory.setPriceStalenessThreshold(vaultAddress, priceStalenesThreshold);
      console.log("  ✅ 价格过期阈值:", priceStalenesThreshold, "秒", `(${priceStalenesThreshold / 3600}小时)`);

      createdVaults.push({
        name: params.name,
        symbol: params.symbol,
        address: vaultAddress,
        index: index.toString(),
        manager: params.manager,
        hardCap: params.hardCap.toString(),
        redemptionTime: params.redemptionTime,
        ytPrice: ytPrice.toString()
      });
    }
  }

  // ==================== 3. 输出摘要 ====================
  console.log("\n===== 创建完成！=====");
  console.log("\n📋 创建的Vaults:");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  createdVaults.forEach((vault, i) => {
    console.log(`${i + 1}. ${vault.name} (${vault.symbol})`);
    console.log(`   地址: ${vault.address}`);
    console.log(`   索引: ${vault.index}`);
  });
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // 更新部署文件，添加创建的vaults
  vaultDeployment.vaults = createdVaults;
  vaultDeployment.lastUpdate = new Date().toISOString();

  fs.writeFileSync(
    "./deployments-vault-system.json",
    JSON.stringify(vaultDeployment, null, 2)
  );
  console.log("\n✅ Vault信息已保存到 deployments-vault-system.json");

  console.log("\n💡 下一步:");
  console.log("1. 在YTLp系统中将这些vault添加到白名单");
  console.log("2. 为每个vault设置初始价格");
  console.log("3. 开始使用！");
  console.log("\n注意: USDC价格自动从Chainlink获取，无需手动设置");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
