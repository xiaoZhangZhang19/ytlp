import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTPoolManager 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTPoolManager 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTPoolManager?.proxy) {
        throw new Error("未找到 YTPoolManager 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTPoolManager Proxy:          ", deployments.contracts.YTPoolManager.proxy);
    console.log("  YTPoolManager Implementation: ", deployments.contracts.YTPoolManager.implementation);
    console.log("");

    // ========== 升级 YTPoolManager ==========
    console.log("🔄 Phase 1: 升级 YTPoolManager 代理合约");

    // 获取新的 YTPoolManager 合约工厂
    const YTPoolManagerV2 = await ethers.getContractFactory("YTPoolManager");

    console.log("  正在验证新实现合约...");
    const upgradedYTPoolManager = await upgrades.upgradeProxy(
        deployments.contracts.YTPoolManager.proxy,
        YTPoolManagerV2,
        {
            kind: "uups"
        }
    );
    await upgradedYTPoolManager.waitForDeployment();

    console.log("  ✅ YTPoolManager 已升级！");

    // 获取新的实现合约地址
    const upgradedYTPoolManagerAddress = await upgradedYTPoolManager.getAddress();
    const newYTPoolManagerImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedYTPoolManagerAddress);
    console.log("  新 YTPoolManager Implementation:", newYTPoolManagerImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTPoolManager Proxy (不变):", upgradedYTPoolManagerAddress);
    console.log("  Gov:", await upgradedYTPoolManager.gov()); 
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTPoolManager",
        oldImplementation: deployments.contracts.YTPoolManager.implementation,
        newImplementation: newYTPoolManagerImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.YTPoolManager.implementation = newYTPoolManagerImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTPoolManager Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTPoolManager Implementation:");
    console.log("  ", newYTPoolManagerImplAddress);
    console.log("");
    console.log("YTPoolManager Proxy (不变):");
    console.log("  ", deployments.contracts.YTPoolManager.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
