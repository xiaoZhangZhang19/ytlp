import { ethers } from "hardhat";
import * as fs from "fs";

/**
 * 将YTAssetVault添加到YTVault白名单并设置价格
 */
async function main() {
  console.log("开始添加Vault到白名单...\n");

  const [deployer] = await ethers.getSigners();
  console.log("操作账户:", deployer.address);

  // ==================== 1. 读取部署地址 ====================
  console.log("\n===== 1. 读取部署地址 =====");

  // 读取YTLp系统部署信息
  const ytlpDeployment = JSON.parse(fs.readFileSync("./deployments-ytlp.json", "utf8"));
  const priceFeedAddress = ytlpDeployment.contracts.YTPriceFeed.proxy;
  const vaultAddress = ytlpDeployment.contracts.YTVault.proxy;

  console.log("YTPriceFeed:", priceFeedAddress);
  console.log("YTVault:    ", vaultAddress);

  // 读取YTAssetFactory部署信息
  const vaultSystemDeployment = JSON.parse(fs.readFileSync("./deployments-vault-system.json", "utf8"));
  const vaults = vaultSystemDeployment.vaults;

  if (!vaults || vaults.length === 0) {
    throw new Error("未找到YTAssetVault，请先运行 createVault.ts");
  }

  console.log("\n找到", vaults.length, "个YTAssetVault:");
  vaults.forEach((v: any, i: number) => {
    console.log(`  ${i + 1}. ${v.name} (${v.symbol}): ${v.address}`);
  });

  // 读取USDC配置
  const usdcConfig = JSON.parse(fs.readFileSync("./deployments-usdc-config.json", "utf8"));
  const usdcAddress = usdcConfig.contracts.USDC.address;
  console.log("\nUSDC地址:", usdcAddress);

  // 获取合约实例
  const priceFeed = await ethers.getContractAt("YTPriceFeed", priceFeedAddress);
  const vault = await ethers.getContractAt("YTVault", vaultAddress);

  // ==================== 2. 添加到白名单 ====================
  console.log("\n===== 2. 添加到白名单 =====");

  // 配置参数（可根据需要调整）
  // 注意：总权重 = 4000 + 3000 + 2000 + 1000 = 10000
  const whitelistParams = [
    {
      weight: 4000,           // 4000/10000 = 40%
      maxUsdyAmount: ethers.parseEther("45000000"),  // 4500万
      isStable: false
    },
    {
      weight: 3000,           // 3000/10000 = 30%
      maxUsdyAmount: ethers.parseEther("35000000"),  // 3500万
      isStable: false
    },
    {
      weight: 2000,           // 2000/10000 = 20%
      maxUsdyAmount: ethers.parseEther("25000000"),  // 2500万
      isStable: false
    }
  ];

  // 添加YT代币到白名单
  for (let i = 0; i < vaults.length && i < whitelistParams.length; i++) {
    const v = vaults[i];
    const params = whitelistParams[i];

    console.log(`\n添加 ${v.name} (${v.symbol}) 到白名单...`);
    
    const tx = await vault.setWhitelistedToken(
      v.address,
      18,  // decimals
      params.weight,
      params.maxUsdyAmount,
      params.isStable
    );
    await tx.wait();

    console.log("  ✅ 权重:", params.weight);
    console.log("  ✅ 最大USDY:", ethers.formatEther(params.maxUsdyAmount));
    console.log("  ✅ 是否稳定币:", params.isStable);
  }

  // 添加USDC到白名单
  console.log("\n添加 USDC 到白名单...");
  const usdcParams = {
    weight: 1000,           // 1000/10000 = 10%
    maxUsdyAmount: ethers.parseUnits("30000000", 18), // 3000万 USDC
    isStable: true          // USDC是稳定币
  };

  const usdcTx = await vault.setWhitelistedToken(
    usdcAddress,
    18,  // USDC的精度是18
    usdcParams.weight,
    usdcParams.maxUsdyAmount,
    usdcParams.isStable
  );
  await usdcTx.wait();

  console.log("  ✅ 权重:", usdcParams.weight);
  console.log("  ✅ 最大USDY:", ethers.formatEther(usdcParams.maxUsdyAmount));
  console.log("  ✅ 是否稳定币:", usdcParams.isStable);

  // ==================== 3. 设置YT价格 ====================
  console.log("\n===== 3. 设置YT价格 =====");

  for (const v of vaults) {
    console.log(`\n设置 ${v.name} (${v.symbol}) 价格...`);
    
    // 使用vault中保存的初始价格（已经是1e30精度，直接使用）
    const price = v.ytPrice;
    
    const tx = await priceFeed.forceUpdatePrice(
      v.address,
      price
    );
    await tx.wait();

    console.log("  ✅ YT价格已设置:", ethers.formatUnits(price, 30), "(精度1e30)");
  }

  console.log("\n✅ USDC价格从Chainlink自动获取，无需手动设置");

  // ==================== 4. 验证配置 ====================
  console.log("\n===== 4. 验证配置 =====");

  for (const v of vaults) {
    const isWhitelisted = await vault.whitelistedTokens(v.address);
    const weight = await vault.tokenWeights(v.address);
    const price = await priceFeed.getPrice(v.address, true);

    console.log(`\n${v.name} (${v.symbol}):`);
    console.log("  白名单:", isWhitelisted ? "✅" : "❌");
    console.log("  权重:", weight.toString());
    console.log("  价格:", ethers.formatUnits(price, 30));
  }

  // 验证USDC
  const usdcWhitelisted = await vault.whitelistedTokens(usdcAddress);
  const usdcWeight = await vault.tokenWeights(usdcAddress);
  const usdcIsStable = await vault.stableTokens(usdcAddress);
  const usdcPrice = await priceFeed.getPrice(usdcAddress, true);

  console.log("\nUSDC:");
  console.log("  白名单:", usdcWhitelisted ? "✅" : "❌");
  console.log("  权重:", usdcWeight.toString());
  console.log("  价格:", ethers.formatUnits(usdcPrice, 30), "(从Chainlink获取)");
  console.log("  稳定币:", usdcIsStable ? "✅" : "❌");

  const totalWeight = await vault.totalTokenWeights();
  console.log("\n总权重:", totalWeight.toString());

  // ==================== 5. 输出摘要 ====================
  console.log("\n===== 配置完成！=====");
  console.log("\n✅ 已添加", vaults.length, "个YT代币到白名单");
  console.log("✅ 已添加 USDC 到白名单（稳定币）");
  console.log("✅ 已为所有YT代币设置初始价格");
  console.log("✅ USDC价格从Chainlink自动更新");
  console.log("\n📋 池子组成: USDC/YT-A/YT-B/YT-C");
  console.log("   • USDC: 10% (稳定币, 手续费0.04%)");
  console.log("   • YT-A: 40% (YT代币, 手续费0.3%)");
  console.log("   • YT-B: 30% (YT代币, 手续费0.3%)");
  console.log("   • YT-C: 20% (YT代币, 手续费0.3%)");
  console.log("\n💡 系统已就绪，可以开始使用！");

  // 保存配置信息
  const configInfo = {
    timestamp: new Date().toISOString(),
    operator: deployer.address,
    whitelistedTokens: {
      ytTokens: vaults.map((v: any, i: number) => ({
        name: v.name,
        symbol: v.symbol,
        address: v.address,
        weight: whitelistParams[i]?.weight || 0,
        maxUsdyAmount: whitelistParams[i]?.maxUsdyAmount.toString() || "0",
        price: v.ytPrice,
        isStable: false
      })),
      usdc: {
        name: "USDC",
        symbol: "USDC",
        address: usdcAddress,
        weight: usdcParams.weight,
        maxUsdyAmount: usdcParams.maxUsdyAmount.toString(),
        priceSource: "Chainlink (自动)",
        isStable: true
      }
    },
    totalWeight: totalWeight.toString(),
    poolComposition: "USDC/YT-A/YT-B/YT-C"
  };

  fs.writeFileSync(
    "./deployments-whitelist-config.json",
    JSON.stringify(configInfo, null, 2)
  );
  console.log("\n✅ 白名单配置信息已保存到 deployments-whitelist-config.json");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
