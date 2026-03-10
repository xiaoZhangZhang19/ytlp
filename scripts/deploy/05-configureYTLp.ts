import { ethers } from "hardhat";
import * as fs from "fs";

/**
 * 配置YTLp系统的权限和参数
 * 需要先运行 deployYTLp.ts 和 deployAsset.ts
 */
async function main() {
  console.log("开始配置YT协议...\n");

  const [deployer] = await ethers.getSigners();
  console.log("配置账户:", deployer.address);
  console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ==================== 1. 读取部署地址 ====================
  console.log("===== 1. 读取部署地址 =====");

  // 读取YTLp系统部署信息
  const ytlpDeployment = JSON.parse(fs.readFileSync("./deployments-ytlp.json", "utf8"));
  const usdyAddress = ytlpDeployment.contracts.USDY.proxy;
  const ytLPAddress = ytlpDeployment.contracts.YTLPToken.proxy;
  const priceFeedAddress = ytlpDeployment.contracts.YTPriceFeed.proxy;
  const vaultAddress = ytlpDeployment.contracts.YTVault.proxy;
  const poolManagerAddress = ytlpDeployment.contracts.YTPoolManager.proxy;
  const routerAddress = ytlpDeployment.contracts.YTRewardRouter.proxy;

  console.log("USDY:           ", usdyAddress);
  console.log("YTLPToken:      ", ytLPAddress);
  console.log("YTPriceFeed:    ", priceFeedAddress);
  console.log("YTVault:        ", vaultAddress);
  console.log("YTPoolManager:  ", poolManagerAddress);
  console.log("YTRewardRouter: ", routerAddress);

  // 读取YTAssetFactory部署信息（可选）
  let factoryAddress: string | undefined;
  let firstVaultAddress: string | undefined;
  
  if (fs.existsSync("./deployments-vault-system.json")) {
    const vaultDeployment = JSON.parse(fs.readFileSync("./deployments-vault-system.json", "utf8"));
    factoryAddress = vaultDeployment.contracts.YTAssetFactory.proxy;
    console.log("YTAssetFactory: ", factoryAddress);
    
    // 如果有创建的vault，读取第一个作为wusdPriceSource
    if (vaultDeployment.vaults && vaultDeployment.vaults.length > 0) {
      firstVaultAddress = vaultDeployment.vaults[0].address;
      console.log("第一个Vault:    ", firstVaultAddress);
    }
  }

  // 获取合约实例
  const usdy = await ethers.getContractAt("USDY", usdyAddress);
  const ytLP = await ethers.getContractAt("YTLPToken", ytLPAddress);
  const priceFeed = await ethers.getContractAt("YTPriceFeed", priceFeedAddress);
  const vault = await ethers.getContractAt("YTVault", vaultAddress);
  const poolManager = await ethers.getContractAt("YTPoolManager", poolManagerAddress);

  // ==================== 2. 配置权限 ====================
  console.log("\n===== 2. 配置权限 =====");

  // 配置USDY权限
  console.log("配置USDY vault权限...");
  await usdy.addVault(vaultAddress);
  console.log("  ✅ 添加YTVault");
  await usdy.addVault(poolManagerAddress);
  console.log("  ✅ 添加YTPoolManager");

  // 配置YTLPToken权限
  console.log("配置YTLPToken权限...");
  await ytLP.setMinter(poolManagerAddress, true);
  console.log("  ✅ 设置YTPoolManager为minter");
  await ytLP.setPoolManager(poolManagerAddress);
  console.log("  ✅ 设置PoolManager（用于转账时继承冷却时间）");

  // 配置Vault权限
  console.log("配置YTVault权限...");
  await vault.setPoolManager(poolManagerAddress);
  console.log("  ✅ 设置PoolManager");
  await vault.setSwapper(routerAddress, true);
  console.log("  ✅ 添加Router为swapper");

  // 配置PoolManager权限
  console.log("配置YTPoolManager handler权限...");
  await poolManager.setHandler(routerAddress, true);
  console.log("  ✅ 添加Router为handler");

  // ==================== 3. 配置YTPriceFeed ====================
  console.log("\n===== 3. 配置YTPriceFeed =====");

  // USDC价格从Chainlink获取，无需设置价格来源
  console.log("✅ USDC价格从Chainlink自动获取");
  
  // 根据网络设置价格过期阈值
  const network = await ethers.provider.getNetwork();
  const isTestnet = network.chainId === 97n || network.chainId === 11155111n; // BSC测试网或Sepolia
  const priceStalenesThreshold = isTestnet ? 86400 : 3600; // 测试网24小时，主网1小时
  
  console.log("设置价格过期阈值...");
  await priceFeed.setPriceStalenessThreshold(priceStalenesThreshold);
  console.log("  ✅ 阈值:", priceStalenesThreshold, "秒", `(${priceStalenesThreshold / 3600}小时)`);
  
  // 设置keeper权限（默认设置deployer为keeper）
  console.log("设置Keeper权限...");
  await priceFeed.setKeeper(deployer.address, true);
  console.log("  ✅ 添加Keeper:", deployer.address);

  // 设置价格保护参数
  console.log("设置价格保护参数...");
  const maxPriceChangeBps = 500; // 5%
  await priceFeed.setMaxPriceChangeBps(maxPriceChangeBps);
  console.log("  ✅ 最大价格变动:", maxPriceChangeBps / 100, "%");

  // ==================== 4. 配置YTVault参数 ====================
  console.log("\n===== 4. 配置YTVault参数 =====");

  // 设置动态费率（初始关闭）
  console.log("设置动态费率...");
  await vault.setDynamicFees(true);
  console.log("  ✅ 动态费率: 开启");

  // 设置最大滑点
  console.log("设置最大滑点...");
  const maxSwapSlippageBps = 1000; // 10%
  await vault.setMaxSwapSlippageBps(maxSwapSlippageBps);
  console.log("  ✅ 最大滑点:", maxSwapSlippageBps / 100, "%");

  // ==================== 5. 配置YTPoolManager参数 ====================
  console.log("\n===== 5. 配置YTPoolManager参数 =====");

  // ==================== 6. 输出配置摘要 ====================
  console.log("\n===== 配置完成！=====");
  console.log("\n📋 权限配置:");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("✅ USDY vaults: YTVault, YTPoolManager");
  console.log("✅ YTLPToken minter: YTPoolManager");
  console.log("✅ YTLPToken poolManager: YTPoolManager (冷却时间保护)");
  console.log("✅ YTVault poolManager: YTPoolManager");
  console.log("✅ YTVault swapper: YTRewardRouter");
  console.log("✅ YTPoolManager handler: YTRewardRouter");
  console.log("✅ YTPriceFeed keeper:", deployer.address);
  console.log("✅ USDC价格: 从Chainlink自动获取");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  console.log("\n📋 参数配置:");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("✅ 动态费率: 开启");
  console.log("✅ 最大滑点:", maxSwapSlippageBps / 100, "%");
  console.log("✅ 最大价格变动:", maxPriceChangeBps / 100, "%");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // 保存配置信息
  const configInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    configurer: deployer.address,
    timestamp: new Date().toISOString(),
    configuration: {
      permissions: {
        usdyVaults: [vaultAddress, poolManagerAddress],
        ytlpMinters: [poolManagerAddress],
        ytlpPoolManager: poolManagerAddress,
        vaultPoolManager: poolManagerAddress,
        vaultSwappers: [routerAddress],
        poolManagerHandlers: [routerAddress],
        priceFeedKeepers: [deployer.address],
        usdcPriceSource: "Chainlink (自动)"
      },
      parameters: {
        dynamicFees: true,
        maxSwapSlippageBps,
        maxPriceChangeBps
      }
    }
  };

  fs.writeFileSync(
    "./deployments-ytlp-config.json",
    JSON.stringify(configInfo, null, 2)
  );
  console.log("\n✅ 配置信息已保存到 deployments-ytlp-config.json");

  console.log("\n💡 下一步:");
  console.log("1. 运行 04-createVault.ts 通过YTAssetFactory创建YTAssetVault代币");
  console.log("2. 运行 06-addVaultToWhitelist.ts 将YTAssetVault添加到白名单");
  console.log("3. 开始使用协议！");
  console.log("\n注意: USDC价格自动从Chainlink获取，无需手动设置");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
