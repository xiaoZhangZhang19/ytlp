import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 部署 Lending 借贷池系统
 * 包含：LendingFactory, Configurator, LendingPriceFeed, Lending 实现和代理
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("📦 部署 Lending 借贷池系统");
    console.log("==========================================");
    console.log("部署账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    const deployments: any = {};

    // ========== 读取配置参数 ==========
    console.log("📋 读取配置参数...");
    
    const network = await ethers.provider.getNetwork();
    const chainId = network.chainId.toString();
    
    let USDC_ADDRESS: string;
    let USDC_PRICE_FEED: string;

    if (chainId === "421614") {
        // Arbitrum 测试网
        USDC_ADDRESS = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
        USDC_PRICE_FEED = "0x0153002d20B96532C639313c2d54c3dA09109309"; // USDC/USD
    } else if (chainId === "56") {
        // BSC 主网
        USDC_ADDRESS = "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d";
        USDC_PRICE_FEED = "0x51597f405303C4377E36123cBc172b13269EA163"; // USDC/USD
    } 
    else if (chainId === "97") {
        // BSC 测试网
        USDC_ADDRESS = "0x939cf46F7A4d05da2a37213E7379a8b04528F590";
        USDC_PRICE_FEED = "0x90c069C4538adAc136E051052E14c1cD799C41B7"; // USDC/USD
    } else {
        throw new Error(`不支持的网络: ${chainId}`);
    }
    
    console.log("  USDC 地址:", USDC_ADDRESS);
    console.log("  USDC Price Feed:", USDC_PRICE_FEED, "\n");

    // ========== 第一阶段：部署工厂合约 ==========
    console.log("📦 Phase 1: 部署 LendingFactory...");
    const LendingFactory = await ethers.getContractFactory("LendingFactory");
    const lendingFactory = await LendingFactory.deploy();
    await lendingFactory.waitForDeployment();
    const lendingFactoryAddress = await lendingFactory.getAddress();
    console.log("✅ LendingFactory 已部署:", lendingFactoryAddress);
    deployments.lendingFactory = lendingFactoryAddress;

    // ========== 第二阶段：部署 LendingPriceFeed (UUPS 代理) ==========
    console.log("\n📦 Phase 2: 部署 LendingPriceFeed (UUPS 代理)...");
    const LendingPriceFeed = await ethers.getContractFactory("LendingPriceFeed");
    
    // 使用 upgrades 插件部署 UUPS 代理
    const lendingPriceFeed = await upgrades.deployProxy(
        LendingPriceFeed,
        [USDC_ADDRESS, USDC_PRICE_FEED],
        {
            kind: "uups",
            initializer: "initialize"
        }
    );
    await lendingPriceFeed.waitForDeployment();
    
    const lendingPriceFeedProxyAddress = await lendingPriceFeed.getAddress();
    console.log("✅ LendingPriceFeed Proxy:", lendingPriceFeedProxyAddress);
    deployments.lendingPriceFeedProxy = lendingPriceFeedProxyAddress;
    deployments.lendingPriceFeed = lendingPriceFeedProxyAddress; // 兼容旧字段
    
    // 获取实现合约地址
    const lendingPriceFeedImplAddress = await upgrades.erc1967.getImplementationAddress(lendingPriceFeedProxyAddress);
    console.log("✅ LendingPriceFeed Implementation:", lendingPriceFeedImplAddress);
    deployments.lendingPriceFeedImpl = lendingPriceFeedImplAddress;
    
    // 根据网络设置价格过期阈值（必须在验证价格之前设置）
    const isTestnet = network.chainId === 97n || network.chainId === 11155111n; // BSC测试网或Sepolia
    const priceStalenesThreshold = isTestnet ? 86400 : 3600; // 测试网24小时，主网1小时
    const setThresholdTx = await lendingPriceFeed.setPriceStalenessThreshold(priceStalenesThreshold);
    await setThresholdTx.wait(); // 等待交易确认
    console.log("✅ 价格过期阈值已设置:", priceStalenesThreshold, "秒", `(${priceStalenesThreshold / 3600}小时)`);
    
    // 验证价格获取
    const usdcPrice = await lendingPriceFeed.getPrice(USDC_ADDRESS);
    console.log("✅ USDC 价格 (1e30 精度):", usdcPrice.toString());
    console.log("✅ LendingPriceFeed Owner:", await lendingPriceFeed.owner());

    // ========== 第三阶段：部署 Configurator ==========
    console.log("\n📦 Phase 3: 部署 Configurator (UUPS 代理)...");
    const Configurator = await ethers.getContractFactory("Configurator");
    
    // 使用 upgrades 插件部署 UUPS 代理
    const configurator = await upgrades.deployProxy(
        Configurator,
        [],
        {
            kind: "uups",
            initializer: "initialize"
        }
    );
    await configurator.waitForDeployment();
    
    const configuratorProxyAddress = await configurator.getAddress();
    console.log("✅ Configurator Proxy:", configuratorProxyAddress);
    deployments.configuratorProxy = configuratorProxyAddress;
    
    // 获取实现合约地址
    const configuratorImplAddress = await upgrades.erc1967.getImplementationAddress(configuratorProxyAddress);
    console.log("✅ Configurator Implementation:", configuratorImplAddress);
    deployments.configuratorImpl = configuratorImplAddress;
    
    console.log("✅ Configurator Owner:", await configurator.owner());

    // ========== 第四阶段：部署 Lending 实现合约 ==========
    console.log("\n📦 Phase 4: 通过工厂部署 Lending 实现合约...");
    const deployTx = await lendingFactory.deploy();
    const deployReceipt = await deployTx.wait();
    
    // 使用 logs 和 interface.parseLog 解析事件
    let lendingImplAddress;
    for (const log of deployReceipt.logs) {
        try {
            const parsedLog = lendingFactory.interface.parseLog({
                topics: [...log.topics],
                data: log.data
            });
            if (parsedLog && parsedLog.name === 'LendingDeployed') {
                lendingImplAddress = parsedLog.args.lending;
                break;
            }
        } catch (e) {
            // 忽略无法解析的日志
            continue;
        }
    }
    
    console.log("✅ Lending Implementation:", lendingImplAddress);
    deployments.lendingImpl = lendingImplAddress;

    // ========== 第五阶段：准备部署 Lending 代理 ==========
    console.log("\n📦 Phase 5: 准备部署 Lending 代理（需要先配置参数）");
    console.log("⚠️  请运行配置脚本 08-configureLending.ts 来完成配置和代理部署");

    // ========== 保存部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-lending.json");
    const existingDeployments = fs.existsSync(deploymentsPath) 
        ? JSON.parse(fs.readFileSync(deploymentsPath, "utf-8")) 
        : {};
    
    existingDeployments[chainId] = {
        ...existingDeployments[chainId],
        ...deployments,
        usdcAddress: USDC_ADDRESS,
        usdcPriceFeed: USDC_PRICE_FEED,
        deployTimestamp: new Date().toISOString(),
        deployer: deployer.address
    };
    
    fs.writeFileSync(deploymentsPath, JSON.stringify(existingDeployments, null, 2));
    console.log("\n💾 部署信息已保存到:", deploymentsPath);

    // ========== 部署总结 ==========
    console.log("\n🎉 部署总结:");
    console.log("=====================================");
    console.log("📍 外部依赖:");
    console.log("  USDC Address:            ", USDC_ADDRESS);
    console.log("  USDC Price Feed:         ", USDC_PRICE_FEED);
    console.log("\n📦 已部署合约:");
    console.log("  LendingFactory:          ", deployments.lendingFactory);
    console.log("\n📊 LendingPriceFeed (UUPS):");
    console.log("  Proxy:                   ", deployments.lendingPriceFeedProxy);
    console.log("  Implementation:          ", deployments.lendingPriceFeedImpl);
    console.log("\n⚙️  Configurator (UUPS):");
    console.log("  Proxy:                   ", deployments.configuratorProxy);
    console.log("  Implementation:          ", deployments.configuratorImpl);
    console.log("\n🏦 Lending:");
    console.log("  Implementation:          ", deployments.lendingImpl);
    console.log("  Proxy:                   ", "待配置");
    console.log("=====================================");
    console.log("\n💡 下一步:");
    console.log("  运行 08-configureLending.ts 来创建 Lending 市场\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

