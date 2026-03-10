import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTPriceFeed 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTPriceFeed 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTPriceFeed?.proxy) {
        throw new Error("未找到 YTPriceFeed 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTPriceFeed Proxy:          ", deployments.contracts.YTPriceFeed.proxy);
    console.log("  YTPriceFeed Implementation: ", deployments.contracts.YTPriceFeed.implementation);
    console.log("");

    // ========== 升级 YTPriceFeed ==========
    console.log("🔄 Phase 1: 升级 YTPriceFeed 代理合约");

    // 获取新的 YTPriceFeed 合约工厂
    const YTPriceFeedV2 = await ethers.getContractFactory("YTPriceFeed");

    console.log("  正在验证新实现合约...");
    const upgradedYTPriceFeed = await upgrades.upgradeProxy(
        deployments.contracts.YTPriceFeed.proxy,
        YTPriceFeedV2,
        {
            kind: "uups"
        }
    );
    await upgradedYTPriceFeed.waitForDeployment();

    console.log("  ✅ YTPriceFeed 已升级！");

    // 获取新的实现合约地址
    const upgradedYTPriceFeedAddress = await upgradedYTPriceFeed.getAddress();
    const newYTPriceFeedImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedYTPriceFeedAddress);
    console.log("  新 YTPriceFeed Implementation:", newYTPriceFeedImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTPriceFeed Proxy (不变):", upgradedYTPriceFeedAddress);
    console.log("  Owner:", await upgradedYTPriceFeed.owner());
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTPriceFeed",
        oldImplementation: deployments.contracts.YTPriceFeed.implementation,
        newImplementation: newYTPriceFeedImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.YTPriceFeed.implementation = newYTPriceFeedImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTPriceFeed Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTPriceFeed Implementation:");
    console.log("  ", newYTPriceFeedImplAddress);
    console.log("");
    console.log("YTPriceFeed Proxy (不变):");
    console.log("  ", deployments.contracts.YTPriceFeed.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
