import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 LendingPriceFeed 合约
 * 使用 upgrades.upgradeProxy() 进行 UUPS 升级
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 LendingPriceFeed 合约");
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

    if (!deployments.lendingPriceFeed) {
        throw new Error("未找到 LendingPriceFeed Proxy 地址，请先运行部署脚本");
    }

    console.log("📋 当前部署的合约:");
    console.log("  LendingPriceFeed Proxy:", deployments.lendingPriceFeed);
    if (deployments.lendingPriceFeedImpl) {
        console.log("  LendingPriceFeed Impl: ", deployments.lendingPriceFeedImpl);
    }
    console.log("");

    // ========== 升级 LendingPriceFeed ==========
    console.log("🔄 Phase 1: 升级 LendingPriceFeed 合约");

    console.log("  当前 LendingPriceFeed Proxy:", deployments.lendingPriceFeed);
    if (deployments.lendingPriceFeedImpl) {
        console.log("  当前 LendingPriceFeed Implementation:", deployments.lendingPriceFeedImpl);
    }

    // 获取新的 LendingPriceFeed 合约工厂
    const LendingPriceFeedV2 = await ethers.getContractFactory("LendingPriceFeed");

    console.log("\n  正在验证新实现合约...");
    const upgradedPriceFeed = await upgrades.upgradeProxy(
        deployments.lendingPriceFeed,
        LendingPriceFeedV2,
        {
            kind: "uups"
        }
    );
    await upgradedPriceFeed.waitForDeployment();

    console.log("  ✅ LendingPriceFeed 已升级！");

    // 获取新的实现合约地址
    const upgradedPriceFeedAddress = await upgradedPriceFeed.getAddress();
    const newPriceFeedImplAddress = await upgrades.erc1967.getImplementationAddress(upgradedPriceFeedAddress);
    console.log("  新 LendingPriceFeed Implementation:", newPriceFeedImplAddress);

    // 验证升级
    console.log("\n  验证升级结果:");
    console.log("  LendingPriceFeed Proxy (不变):", upgradedPriceFeedAddress);
    console.log("  Owner:", await upgradedPriceFeed.owner());
    console.log("  USDC Address:", await upgradedPriceFeed.usdcAddress());

    // 保存升级历史
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }

    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        contract: "LendingPriceFeed",
        oldImplementation: deployments.lendingPriceFeedImpl || "未记录",
        newImplementation: newPriceFeedImplAddress,
        upgrader: deployer.address
    });

    // 保存新的实现地址
    deployments.lendingPriceFeedImpl = newPriceFeedImplAddress;
    deployments.lastUpgradeTime = new Date().toISOString();

    allDeployments[chainId] = deployments;
    fs.writeFileSync(deploymentsPath, JSON.stringify(allDeployments, null, 2));

    console.log("\n✅ LendingPriceFeed 升级完成！");
    console.log("=====================================");
    console.log("旧实现:", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("新实现:", newPriceFeedImplAddress);
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
