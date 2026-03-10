import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 Configurator 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 Configurator 合约");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-lending.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件，请先运行部署脚本");
    }

    const network = await ethers.provider.getNetwork();
    const chainId = network.chainId.toString();
    const allDeployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));
    const deployments = allDeployments[chainId];

    if (!deployments) {
        throw new Error(`未找到网络 ${chainId} 的部署信息`);
    }

    console.log("📋 当前部署的合约:");
    console.log("  Configurator Proxy:", deployments.configuratorProxy);
    console.log("  Configurator Impl: ", deployments.configuratorImpl);
    console.log("");

    // ========== 升级 Configurator ==========
    console.log("🔄 Phase 1: 升级 Configurator 合约");

    console.log("  当前 Configurator Proxy:", deployments.configuratorProxy);
    console.log("  当前 Configurator Implementation:", deployments.configuratorImpl);

    // 获取新的 Configurator 合约工厂
    const ConfiguratorV2 = await ethers.getContractFactory("Configurator");

    console.log("\n  正在验证新实现合约...");
    const upgradedConfigurator = await upgrades.upgradeProxy(
        deployments.configuratorProxy,
        ConfiguratorV2,
        {
            kind: "uups",
            // unsafeSkipStorageCheck: true  // 跳过存储布局检查（请确保你了解风险）
        }
    );
    await upgradedConfigurator.waitForDeployment();

    console.log("  ✅ Configurator 已升级！");

    // 获取新的实现合约地址
    const upgradedConfiguratorAddress = await upgradedConfigurator.getAddress();
    const newConfiguratorImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedConfiguratorAddress);
    console.log("  新 Configurator Implementation:", newConfiguratorImplAddress);

    // 验证升级
    console.log("\n  验证升级结果:");
    console.log("  Configurator Proxy (不变):", upgradedConfiguratorAddress);
    console.log("  Owner:", await upgradedConfigurator.owner());

    // 保存升级历史
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "Configurator",
        oldImplementation: deployments.configuratorImpl,
        newImplementation: newConfiguratorImplAddress,
        upgrader: deployer.address
    });

    // 保存新的实现地址
    deployments.configuratorImpl = newConfiguratorImplAddress;
    deployments.configuratorUpgradeTimestamp = new Date().toISOString();

    allDeployments[chainId] = deployments;
    fs.writeFileSync(deploymentsPath, JSON.stringify(allDeployments, null, 2));

    console.log("\n✅ Configurator 升级完成！");
    console.log("=====================================");
    console.log("旧实现:", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("新实现:", newConfiguratorImplAddress);
    console.log("=====================================\n");

    console.log("💾 升级信息已保存到:", deploymentsPath);
    console.log("");
    console.log("📌 重要提示:");
    console.log("  1. 代理地址保持不变，用户无需更改合约地址");
    console.log("  2. 所有状态数据已保留");
    console.log("  3. 建议运行验证脚本确认升级成功");
    console.log("  4. 建议在测试网充分测试后再升级主网\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
