import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 Lending 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 Lending 合约");
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

    if (!deployments.lendingProxy) {
        throw new Error("未找到 Lending Proxy 地址，请先运行配置脚本");
    }

    console.log("📋 当前部署的合约:");
    console.log("  Lending Proxy:", deployments.lendingProxy);
    console.log("  Lending Impl: ", deployments.lendingImpl);
    console.log("");

    // ========== 升级 Lending ==========
    console.log("🔄 Phase 1: 升级 Lending 合约");

    console.log("  当前 Lending Proxy:", deployments.lendingProxy);
    console.log("  当前 Lending Implementation:", deployments.lendingImpl);

    // 获取新的 Lending 合约工厂
    const LendingV2 = await ethers.getContractFactory("Lending");

    console.log("\n  正在验证新实现合约...");
    // upgrades.upgradeProxy 会自动验证存储布局兼容性
    const upgradedLending = await upgrades.upgradeProxy(
        deployments.lendingProxy,
        LendingV2,
        {
            kind: "uups"
        }
    );
    await upgradedLending.waitForDeployment();

    console.log("  ✅ Lending 已升级！");

    // 获取新的实现合约地址
    const upgradedLendingAddress = await upgradedLending.getAddress();
    const newLendingImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedLendingAddress);
    console.log("  新 Lending Implementation:", newLendingImplAddress);

    // 验证升级
    console.log("\n  验证升级结果:");
    console.log("  Lending Proxy (不变):", upgradedLendingAddress);
    console.log("  Owner:", await upgradedLending.owner());
    console.log("  Base Token:", await upgradedLending.baseToken());

    // 保存升级历史
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "Lending",
        oldImplementation: deployments.lendingImpl,
        newImplementation: newLendingImplAddress,
        upgrader: deployer.address
    });

    // 保存新的实现地址
    deployments.lendingImpl = newLendingImplAddress;
    deployments.lendingUpgradeTimestamp = new Date().toISOString();

    allDeployments[chainId] = deployments;
    fs.writeFileSync(deploymentsPath, JSON.stringify(allDeployments, null, 2));

    console.log("\n✅ Lending 升级完成！");
    console.log("=====================================");
    console.log("旧实现:", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("新实现:", newLendingImplAddress);
    console.log("=====================================\n");

    console.log("💾 升级信息已保存到:", deploymentsPath);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
