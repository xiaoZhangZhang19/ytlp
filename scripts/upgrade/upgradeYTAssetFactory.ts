import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTAssetFactory 合约
 *
 * 升级步骤：
 * 1. 部署新的 YTAssetFactory 实现合约
 * 2. 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 * 3. 验证新功能
 *
 * 注意：
 * - 这是 UUPS 代理升级，代理地址保持不变
 * - 所有状态数据已保留
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTAssetFactory 系统");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-vault-system.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件 deployments-vault-system.json，请先运行部署脚本");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));

    if (!deployments.contracts?.YTAssetFactory?.proxy) {
        throw new Error("未找到 YTAssetFactory 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTAssetFactory Proxy:          ", deployments.contracts.YTAssetFactory.proxy);
    console.log("  YTAssetFactory Implementation: ", deployments.contracts.YTAssetFactory.implementation);
    console.log("");

    // ========== Phase 1: 升级 YTAssetFactory ==========
    console.log("🔄 Phase 1: 升级 YTAssetFactory 代理合约");
    console.log("  当前 YTAssetFactory Proxy:", deployments.contracts.YTAssetFactory.proxy);
    console.log("  当前 YTAssetFactory Implementation:", deployments.contracts.YTAssetFactory.implementation);

    // 获取新的 YTAssetFactory 合约工厂
    const YTAssetFactoryV2 = await ethers.getContractFactory("YTAssetFactory");

    console.log("\n  正在验证新实现合约...");
    const upgradedFactory = await upgrades.upgradeProxy(
        deployments.contracts.YTAssetFactory.proxy,
        YTAssetFactoryV2,
        {
            kind: "uups"
        }
    );
    await upgradedFactory.waitForDeployment();

    console.log("  ✅ YTAssetFactory 已升级！");

    // 获取新的实现合约地址
    const upgradedFactoryAddress = await upgradedFactory.getAddress();
    const newFactoryImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedFactoryAddress);
    console.log("  新 YTAssetFactory Implementation:", newFactoryImplAddress);
    console.log("");

    // ========== Phase 2: 验证升级结果 ==========
    console.log("🔄 Phase 2: 验证升级结果");

    console.log("  YTAssetFactory Proxy (不变):", upgradedFactoryAddress);
    console.log("  Owner:", await upgradedFactory.owner());
    console.log("  Vault Implementation:", await upgradedFactory.vaultImplementation());
    console.log("  USDC Address:", await upgradedFactory.usdcAddress());
    console.log("");

    // ========== 保存更新的部署信息 ==========
    // 保存旧的实现地址作为历史记录
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "YTAssetFactory",
        oldImplementation: deployments.contracts.YTAssetFactory.implementation,
        newImplementation: newFactoryImplAddress,
        upgrader: deployer.address
    });

    // 更新当前实现地址
    deployments.contracts.YTAssetFactory.implementation = newFactoryImplAddress;
    deployments.lastUpdate = new Date().toISOString();

    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTAssetFactory Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTAssetFactory Implementation:");
    console.log("  ", newFactoryImplAddress);
    console.log("");
    console.log("Factory Proxy (不变):");
    console.log("  ", deployments.contracts.YTAssetFactory.proxy);
    console.log("=====================================\n");

    console.log("✅ 升级完成！");
    console.log("");
    console.log("📌 重要提示:");
    console.log("  1. YTAssetFactory 代理地址保持不变");
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
