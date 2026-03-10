import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 配置 Lending 借贷池参数并部署代理
 * 包含：配置市场参数、添加 YT 抵押资产、部署 Lending 代理
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("⚙️  配置 Lending 借贷池");
    console.log("==========================================");
    console.log("配置账户:", deployer.address, "\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-lending.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行 07-deployLending.ts");
    }
    
    const network = await ethers.provider.getNetwork();
    const chainId = network.chainId.toString();
    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"))[chainId];
    
    if (!deployments) {
        throw new Error(`未找到网络 ${chainId} 的部署信息`);
    }

    console.log("📋 使用已部署的合约:");
    console.log("  LendingFactory:", deployments.lendingFactory);
    console.log("  LendingPriceFeed (Proxy):", deployments.lendingPriceFeed);
    if (deployments.lendingPriceFeedImpl) {
        console.log("  LendingPriceFeed (Impl):", deployments.lendingPriceFeedImpl);
    }
    console.log("  Configurator (Proxy):", deployments.configuratorProxy);
    console.log("  Lending (Impl):", deployments.lendingImpl);
    console.log("  USDC Address:", deployments.usdcAddress);
    console.log("  USDC Price Feed:", deployments.usdcPriceFeed, "\n");

    // ========== 配置 LendingPriceFeed 价格过期阈值 ==========
    console.log("⚙️  配置 LendingPriceFeed 价格过期阈值");
    const lendingPriceFeed = await ethers.getContractAt("LendingPriceFeed", deployments.lendingPriceFeed);
    
    // 根据网络设置价格过期阈值
    const isTestnet = network.chainId === 97n || network.chainId === 11155111n; // BSC测试网或Sepolia
    const priceStalenesThreshold = isTestnet ? 86400 : 3600; // 测试网24小时，主网1小时
    
    await lendingPriceFeed.setPriceStalenessThreshold(priceStalenesThreshold);
    console.log("  ✅ 阈值:", priceStalenesThreshold, "秒", `(${priceStalenesThreshold / 3600}小时)\n`);

    // ========== 读取 YT Vault 部署信息 ==========
    const vaultDeploymentsPath = path.join(__dirname, "../../deployments-vault-system.json");
    if (!fs.existsSync(vaultDeploymentsPath)) {
        throw new Error("未找到 YT Vault 部署信息文件，请先部署 YT Vault 系统");
    }
    
    const vaultDeployments = JSON.parse(fs.readFileSync(vaultDeploymentsPath, "utf-8"));
    if (!vaultDeployments.vaults || vaultDeployments.vaults.length === 0) {
        throw new Error("未找到已部署的 YT Vault，请先创建至少一个 YT Vault");
    }
    
    console.log("📋 找到 YT Vaults:", vaultDeployments.vaults.length);
    vaultDeployments.vaults.forEach((vault: any, index: number) => {
        console.log(`  ${index + 1}. ${vault.name} (${vault.symbol}): ${vault.address}`);
    });
    console.log();

    // ========== 第一阶段：配置参数 ==========
    console.log("⚙️  Phase 1: 准备配置参数");
    
    const USDC = {
        address: deployments.usdcAddress,
        decimals: 18
    };

    // 选择要作为抵押品的 YT Vaults（可以选择多个）
    // todo: 根据需要修改这里，选择哪些 YT Vault 作为抵押品
    const selectedVaults = vaultDeployments.vaults.slice(0, 3); // 默认选择前3个
    
    console.log("  选择的抵押品 YT Vaults:");
    selectedVaults.forEach((vault: any, index: number) => {
        console.log(`    ${index + 1}. ${vault.name}: ${vault.address}`);
    });
    console.log();
    
    // 准备抵押资产配置
    const assetConfigs = selectedVaults.map((vault: any) => ({
        asset: vault.address,
        decimals: 18, // YT Token 都是 18 decimals
        borrowCollateralFactor: ethers.parseUnits("0.80", 18),       // 80% LTV
        liquidateCollateralFactor: ethers.parseUnits("0.85", 18),    // 85% 清算线
        liquidationFactor: ethers.parseUnits("0.95", 18),            // 95% (配合 storeFrontPriceFactor 产生折扣)
        supplyCap: ethers.parseUnits("100000", 18)                   // 最多 10 万 YT
    }));

    // ========== 第二阶段：准备配置参数 ==========
    console.log("⚙️  Phase 2: 准备市场配置参数");
    
    const configuration = {
        baseToken: USDC.address,
        lendingPriceSource: deployments.lendingPriceFeed,
        
        // 利率模型参数（年化利率，18位精度）
        // 注意：这些年化利率会在 initialize 时自动转换为每秒利率
        // 转换公式：perSecondRate = perYearRate / 31,536,000
        supplyKink: ethers.parseUnits("0.8", 18),                        // 80% 利用率拐点
        supplyPerYearInterestRateSlopeLow: ethers.parseUnits("0.03", 18),   // 3% APY
        supplyPerYearInterestRateSlopeHigh: ethers.parseUnits("0.4", 18),   // 40% APY
        supplyPerYearInterestRateBase: ethers.parseUnits("0", 18),          // 0% 基础
        
        borrowKink: ethers.parseUnits("0.8", 18),                        // 80% 利用率拐点
        borrowPerYearInterestRateSlopeLow: ethers.parseUnits("0.05", 18),   // 5% APY
        borrowPerYearInterestRateSlopeHigh: ethers.parseUnits("1.5", 18),   // 150% APY
        borrowPerYearInterestRateBase: ethers.parseUnits("0.015", 18),      // 1.5% 基础
        
        storeFrontPriceFactor: ethers.parseUnits("0.5", 18),             // 50% 清算折扣
        baseBorrowMin: ethers.parseUnits("100", USDC.decimals),          // 最小借 100 USDC
        targetReserves: ethers.parseUnits("5000000", USDC.decimals),     // 目标储备 500 万
        
        assetConfigs: assetConfigs
    };
    
    console.log("✅ 配置参数已准备");
    console.log("  基础资产: USDC (6 decimals)");
    console.log("  价格源: LendingPriceFeed");
    console.log("  抵押资产数量:", assetConfigs.length);
    console.log("  Supply Kink: 80%");
    console.log("  Borrow Kink: 80%");
    console.log("  最小借款: 100 USDC");
    console.log("  目标储备: 5,000,000 USDC\n");

    // ========== 第三阶段：部署 Lending 代理 ==========
    console.log("⚙️  Phase 3: 部署 Lending 代理");
    
    const Lending = await ethers.getContractFactory("Lending");
    
    // 使用 upgrades 插件部署 UUPS 代理
    const lending = await upgrades.deployProxy(
        Lending,
        [configuration],
        {
            kind: "uups",
            initializer: "initialize"
        }
    );
    await lending.waitForDeployment();
    const lendingProxyAddress = await lending.getAddress();
    console.log("✅ Lending Proxy 已部署:", lendingProxyAddress);
    
    // 获取实现合约地址（验证）
    const lendingImplAddress = await upgrades.erc1967.getImplementationAddress(lendingProxyAddress);
    console.log("✅ Lending Implementation (验证):", lendingImplAddress);
    
    // 验证基本信息
    console.log("\n📊 验证部署信息:");
    const baseToken = await lending.baseToken();
    const priceSource = await lending.lendingPriceSource();
    const totalSupply = await lending.getTotalSupply();
    const totalBorrow = await lending.getTotalBorrow();
    
    console.log("  Base Token:", baseToken);
    console.log("  Price Source:", priceSource);
    console.log("  Total Supply:", totalSupply.toString());
    console.log("  Total Borrow:", totalBorrow.toString());
    console.log();

    // ========== 保存部署信息 ==========
    deployments.lendingProxy = lendingProxyAddress;
    deployments.collateralAssets = selectedVaults.map((v: any) => ({
        name: v.name,
        symbol: v.symbol,
        address: v.address
    }));
    deployments.configTimestamp = new Date().toISOString();
    
    const allDeployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));
    allDeployments[chainId] = deployments;
    fs.writeFileSync(deploymentsPath, JSON.stringify(allDeployments, null, 2));
    
    console.log("💾 配置信息已保存到:", deploymentsPath);

    // ========== 配置总结 ==========
    console.log("\n🎉 部署和配置完成!");
    console.log("=====================================");
    console.log("Lending Proxy:             ", lendingProxyAddress);
    console.log("Base Token (USDC):         ", USDC.address);
    console.log("Price Feed:                ", deployments.lendingPriceFeed);
    console.log("Collateral Assets:         ", configuration.assetConfigs.length);
    console.log("Supply Kink:               ", "80%");
    console.log("Borrow Kink:               ", "80%");
    console.log("Min Borrow:                ", "100 USDC");
    console.log("Target Reserves:           ", "5,000,000 USDC");
    console.log("=====================================");
    console.log("\n📋 抵押资产列表:");
    selectedVaults.forEach((vault: any, index: number) => {
        console.log(`  ${index + 1}. ${vault.name} (${vault.symbol})`);
        console.log(`     地址: ${vault.address}`);
        console.log(`     LTV: 80%, 清算线: 85%`);
    });
    console.log("=====================================\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

