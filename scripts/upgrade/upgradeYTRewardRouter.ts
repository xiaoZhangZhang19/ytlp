import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTRewardRouter 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTRewardRouter 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTRewardRouter?.proxy) {
        throw new Error("未找到 YTRewardRouter 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTRewardRouter Proxy:          ", deployments.contracts.YTRewardRouter.proxy);
    console.log("  YTRewardRouter Implementation: ", deployments.contracts.YTRewardRouter.implementation);
    console.log("");

    // ========== 升级 YTRewardRouter ==========
    console.log("🔄 Phase 1: 升级 YTRewardRouter 代理合约");

    // 获取新的 YTRewardRouter 合约工厂
    const YTRewardRouterV2 = await ethers.getContractFactory("YTRewardRouter");

    console.log("  正在验证新实现合约...");
    const upgradedYTRewardRouter = await upgrades.upgradeProxy(
        deployments.contracts.YTRewardRouter.proxy,
        YTRewardRouterV2,
        {
            kind: "uups"
        }
    );
    await upgradedYTRewardRouter.waitForDeployment();

    console.log("  ✅ YTRewardRouter 已升级！");

    // 获取新的实现合约地址
    const upgradedYTRewardRouterAddress = await upgradedYTRewardRouter.getAddress();
    const newYTRewardRouterImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedYTRewardRouterAddress);
    console.log("  新 YTRewardRouter Implementation:", newYTRewardRouterImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTRewardRouter Proxy (不变):", upgradedYTRewardRouterAddress);
    console.log("  Owner:", await upgradedYTRewardRouter.owner());
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTRewardRouter",
        oldImplementation: deployments.contracts.YTRewardRouter.implementation,
        newImplementation: newYTRewardRouterImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.YTRewardRouter.implementation = newYTRewardRouterImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTRewardRouter Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTRewardRouter Implementation:");
    console.log("  ", newYTRewardRouterImplAddress);
    console.log("");
    console.log("YTRewardRouter Proxy (不变):");
    console.log("  ", deployments.contracts.YTRewardRouter.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
