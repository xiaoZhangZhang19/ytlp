import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 USDY 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 USDY 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-ytlp.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.USDY?.proxy) {
        throw new Error("未找到 USDY 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  USDY Proxy:          ", deployments.contracts.USDY.proxy);
    console.log("  USDY Implementation: ", deployments.contracts.USDY.implementation);
    console.log("");

    // ========== 升级 USDY ==========
    console.log("🔄 Phase 1: 升级 USDY 代理合约");

    // 获取新的 USDY 合约工厂
    const USDYV2 = await ethers.getContractFactory("USDY");

    console.log("  正在验证新实现合约...");
    const upgradedUSDY = await upgrades.upgradeProxy(
        deployments.contracts.USDY.proxy,
        USDYV2,
        {
            kind: "uups"
        }
    );
    await upgradedUSDY.waitForDeployment();

    console.log("  ✅ USDY 已升级！");

    // 获取新的实现合约地址
    const upgradedUSDYAddress = await upgradedUSDY.getAddress();
    const newUSDYImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedUSDYAddress);
    console.log("  新 USDY Implementation:", newUSDYImplAddress);
    console.log("");

    // ========== 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  USDY Proxy (不变):", upgradedUSDYAddress);
    console.log("  Name:", await upgradedUSDY.name());
    console.log("  Symbol:", await upgradedUSDY.symbol());
    console.log("  Total Supply:", ethers.formatUnits(await upgradedUSDY.totalSupply(), 6));
    console.log("");

    // ========== 保存更新的部署信息 ==========
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "USDY",
        oldImplementation: deployments.contracts.USDY.implementation,
        newImplementation: newUSDYImplAddress,
        upgrader: deployer.address
    });

    deployments.contracts.USDY.implementation = newUSDYImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 USDY Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 USDY Implementation:");
    console.log("  ", newUSDYImplAddress);
    console.log("");
    console.log("USDY Proxy (不变):");
    console.log("  ", deployments.contracts.USDY.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！");
    console.log("");
    console.log("📌 重要提示:");
    console.log("  1. USDY 代理地址保持不变");
    console.log("  2. 所有状态数据已保留");
    console.log("  3. 建议运行验证脚本确认升级成功");
    console.log("  4. 主网升级前务必充分测试\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
