import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * 升级 YTAssetVault 合约
 * 
 * 升级步骤：
 * 1. 部署新的 YTAssetVault 实现合约
 * 2. 通过 Factory 更新 vaultImplementation 地址
 * 3. 可选：批量升级现有的 Vault 代理合约
 * 
 * 注意：
 * - 升级后，新创建的 vault 将使用新实现
 * - 已存在的 vault 需要手动升级才能使用新功能
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("\n==========================================");
    console.log("🔄 升级 YTAssetVault 系统");
    console.log("==========================================");
    console.log("升级账户:", deployer.address);
    console.log("账户余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // ========== 读取部署信息 ==========
    const deploymentsPath = path.join(__dirname, "../../deployments-vault-system.json");
    if (!fs.existsSync(deploymentsPath)) {
        throw new Error("未找到部署信息文件 deployments-vault-system.json，请先运行部署脚本");
    }
    
    const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf-8"));
    
    if (!deployments.contracts?.YTAssetVault?.implementation) {
        throw new Error("未找到 YTAssetVault 部署信息");
    }

    console.log("📋 当前部署的合约:");
    console.log("  YTAssetVault Implementation (旧):", deployments.contracts.YTAssetVault.implementation);
    console.log("  YTAssetFactory Proxy:          ", deployments.contracts.YTAssetFactory.proxy);
    console.log("  YTAssetFactory Implementation: ", deployments.contracts.YTAssetFactory.implementation);
    console.log("  已创建的 Vaults 数量:          ", deployments.vaults?.length || 0);
    console.log("");

    // ========== Phase 1: 部署新的 YTAssetVault 实现 ==========
    console.log("🔄 Phase 1: 部署新的 YTAssetVault 实现合约");
    console.log("  编译新的 YTAssetVault 合约...");
    
    const YTAssetVaultV2 = await ethers.getContractFactory("YTAssetVault");
    
    console.log("  部署新实现合约...");
    const newVaultImpl = await YTAssetVaultV2.deploy();
    await newVaultImpl.waitForDeployment();
    
    const newVaultImplAddress = await newVaultImpl.getAddress();
    console.log("  ✅ 新 YTAssetVault Implementation:", newVaultImplAddress);
    console.log("");

    // ========== Phase 2: 通过 Factory 更新实现地址 ==========
    console.log("🔄 Phase 2: 通过 Factory 更新 vaultImplementation");
    
    const factory = await ethers.getContractAt(
        "YTAssetFactory",
        deployments.contracts.YTAssetFactory.proxy
    );

    console.log("  当前 Factory 的 vaultImplementation:", await factory.vaultImplementation());
    console.log("  准备更新为新实现地址...");
    
    const updateTx = await factory.setVaultImplementation(newVaultImplAddress);
    await updateTx.wait();
    
    console.log("  ✅ Factory vaultImplementation 已更新！");
    console.log("  新地址:", await factory.vaultImplementation());
    console.log("");

    // ========== Phase 3: 升级现有的 Vault 代理（可选） ==========
    console.log("🔄 Phase 3: 升级现有的 Vault 代理合约");
    
    const existingVaults = deployments.vaults || [];
    
    if (existingVaults.length === 0) {
        console.log("  ⚠️  没有已部署的 Vault，跳过此步骤");
    } else {
        console.log(`  发现 ${existingVaults.length} 个已部署的 Vault\n`);
        
        // 询问是否升级现有 Vault（在实际使用中可以配置）
        const UPGRADE_EXISTING_VAULTS = true; // 设置为 true 自动升级所有 vault
        const VAULTS_TO_UPGRADE: number[] = [0, 1, 2]; // 可以指定要升级的 vault 索引，如 [0, 1]
        
        if (UPGRADE_EXISTING_VAULTS) {
            console.log("  📝 准备升级现有的 Vault 代理合约...\n");
            
            const vaultsToProcess = VAULTS_TO_UPGRADE.length > 0 
                ? VAULTS_TO_UPGRADE 
                : existingVaults.map((_: any, idx: number) => idx);
            
            for (const idx of vaultsToProcess) {
                const vaultInfo = existingVaults[idx];
                if (!vaultInfo) {
                    console.log(`  ⚠️  索引 ${idx} 无效，跳过`);
                    continue;
                }
                
                console.log(`  [${idx + 1}/${vaultsToProcess.length}] 升级 ${vaultInfo.symbol} (${vaultInfo.address})`);
                
                try {
                    // 通过 Factory 调用 upgradeVault
                    const upgradeTx = await factory.upgradeVault(
                        vaultInfo.address,
                        newVaultImplAddress
                    );
                    await upgradeTx.wait();
                    
                    // 验证升级
                    const vault = await ethers.getContractAt("YTAssetVault", vaultInfo.address);
                    const currentImpl = await upgrades.erc1967.getImplementationAddress(vaultInfo.address);
                    
                    if (currentImpl.toLowerCase() === newVaultImplAddress.toLowerCase()) {
                        console.log(`      ✅ 升级成功！新实现: ${currentImpl}`);
                        
                        // 验证新功能（检查是否有排队提现机制）
                        try {
                            const pendingCount = await vault.pendingRequestsCount();
                            console.log(`      ✅ 新功能验证通过（pendingRequestsCount: ${pendingCount}）`);
                        } catch (e) {
                            console.log(`      ⚠️  新功能验证失败，可能升级未完全生效`);
                        }
                        
                        // 更新部署信息中的实现地址
                        vaultInfo.implementationAddress = currentImpl;
                        vaultInfo.lastUpgraded = new Date().toISOString();
                    } else {
                        console.log(`      ⚠️  升级可能未成功，当前实现: ${currentImpl}`);
                    }
                } catch (error: any) {
                    console.log(`      ❌ 升级失败: ${error.message}`);
                }
                console.log("");
            }
        } else {
            console.log("  ℹ️  配置为不自动升级现有 Vault");
            console.log("  💡 提示：可以稍后通过 Factory.upgradeVault() 手动升级\n");
        }
    }

    // ========== 保存更新的部署信息 ==========
    // 保存旧的实现地址作为历史记录
    if (!deployments.upgradeHistory) {
        deployments.upgradeHistory = [];
    }
    
    deployments.upgradeHistory.push({
        timestamp: new Date().toISOString(),
        oldImplementation: deployments.contracts.YTAssetVault.implementation,
        newImplementation: newVaultImplAddress,
        upgrader: deployer.address
    });

    // 更新当前实现地址
    deployments.contracts.YTAssetVault.implementation = newVaultImplAddress;
    deployments.lastUpdate = new Date().toISOString();
    
    fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 2));
    console.log("💾 升级信息已保存到:", deploymentsPath);

    // ========== 升级总结 ==========
    console.log("\n🎉 升级总结:");
    console.log("=====================================");
    console.log("旧 YTAssetVault Implementation:");
    console.log("  ", deployments.upgradeHistory[deployments.upgradeHistory.length - 1].oldImplementation);
    console.log("");
    console.log("新 YTAssetVault Implementation:");
    console.log("  ", newVaultImplAddress);
    console.log("");
    console.log("Factory Proxy (不变):");
    console.log("  ", deployments.contracts.YTAssetFactory.proxy);
    console.log("");
    console.log("已升级的 Vaults:");
    if (existingVaults.length > 0) {
        existingVaults.forEach((v: any, idx: number) => {
            if (v.lastUpgraded) {
                console.log(`  ✅ [${idx}] ${v.symbol}: ${v.address}`);
            } else {
                console.log(`  ⏸️  [${idx}] ${v.symbol}: ${v.address} (未升级)`);
            }
        });
    } else {
        console.log("  (无)");
    }
    console.log("=====================================\n");
    
    console.log("✅ 升级完成！");
    console.log("");
    console.log("📌 重要提示:");
    console.log("  1. Factory 已更新为新实现，新创建的 vault 将使用新版本");
    console.log("  2. 已升级的 vault 代理地址不变，状态数据已保留");
    console.log("  3. 新增功能：");
    console.log("     • 两阶段提现机制（排队领取）");
    console.log("     • WithdrawRequest 请求记录");
    console.log("     • processBatchWithdrawals 批量处理");
    console.log("     • 多个查询函数（请求详情、队列进度等）");
    console.log("  4. 如有未升级的 vault，可通过以下方式升级：");
    console.log("     factory.upgradeVault(vaultAddress, newImplementation)");
    console.log("");
    console.log("📝 下一步:");
    console.log("  1. 在测试环境验证新功能");
    console.log("  2. 测试 withdrawYT 的排队机制");
    console.log("  3. 测试 processBatchWithdrawals 的批量处理");
    console.log("  4. 确认所有查询函数工作正常");
    console.log("  5. 主网升级前务必充分测试\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

