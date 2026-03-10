import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTVault 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTVault 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTVault?.proxy) {
        throw new Error("未找到 YTVault 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTVault Proxy:          ", deployments.contracts.YTVault.proxy);
    console.log("  YTVault Implementation: ", deployments.contracts.YTVault.implementation);
    console.log("");

    // ========== 升级 YTVault ==========
    console.log("🔄 Phase 1: 升级 YTVault 代理合约");

    // 获取新的 YTVault 合约工厂
    const YTVaultV2 = await ethers.getContractFactory("YTVault");

    console.log("  正在验证新实现合约...");
    const upgradedYTVault = await upgrades.upgradeProxy(
        deployments.contracts.YTVault.proxy,
        YTVaultV2,
        {
            kind: "uups"
        }
    );
    await upgradedYTVault.waitForDeployment();

    console.log("  ✅ YTVault 已升级！");

    // 获取新的实现合约地址
    const upgradedYTVaultAddress = await upgradedYTVault.getAddress();
    const newYTVaultImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedYTVaultAddress);
    console.log("  新 YTVault Implementation:", newYTVaultImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTVault Proxy (不变):", upgradedYTVaultAddress);
    console.log("  Owner:", await upgradedYTVault.owner());
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTVault",
        oldImplementation: deployments.contracts.YTVault.implementation,
        newImplementation: newYTVaultImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.YTVault.implementation = newYTVaultImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTVault Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTVault Implementation:");
    console.log("  ", newYTVaultImplAddress);
    console.log("");
    console.log("YTVault Proxy (不变):");
    console.log("  ", deployments.contracts.YTVault.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
