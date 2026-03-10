import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTLPToken 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTLPToken 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTLPToken?.proxy) {
        throw new Error("未找到 YTLPToken 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTLPToken Proxy:          ", deployments.contracts.YTLPToken.proxy);
    console.log("  YTLPToken Implementation: ", deployments.contracts.YTLPToken.implementation);
    console.log("");

    // ========== 升级 YTLPToken ==========
    console.log("🔄 Phase 1: 升级 YTLPToken 代理合约");

    // 获取新的 YTLPToken 合约工厂
    const YTLPTokenV2 = await ethers.getContractFactory("YTLPToken");

    console.log("  正在验证新实现合约...");
    const upgradedYTLPToken = await upgrades.upgradeProxy(
        deployments.contracts.YTLPToken.proxy,
        YTLPTokenV2,
        {
            kind: "uups"
        }
    );
    await upgradedYTLPToken.waitForDeployment();

    console.log("  ✅ YTLPToken 已升级！");

    // 获取新的实现合约地址
    const upgradedYTLPTokenAddress = await upgradedYTLPToken.getAddress();
    const newYTLPTokenImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedYTLPTokenAddress);
    console.log("  新 YTLPToken Implementation:", newYTLPTokenImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTLPToken Proxy (不变):", upgradedYTLPTokenAddress);
    console.log("  Name:", await upgradedYTLPToken.name());
    console.log("  Symbol:", await upgradedYTLPToken.symbol());
    console.log("  Total Supply:", ethers.formatEther(await upgradedYTLPToken.totalSupply()));
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTLPToken",
        oldImplementation: deployments.contracts.YTLPToken.implementation,
        newImplementation: newYTLPTokenImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.YTLPToken.implementation = newYTLPTokenImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTLPToken Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTLPToken Implementation:");
    console.log("  ", newYTLPTokenImplAddress);
    console.log("");
    console.log("YTLPToken Proxy (不变):");
    console.log("  ", deployments.contracts.YTLPToken.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
