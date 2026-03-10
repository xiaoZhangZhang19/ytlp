import hre from 'hardhat';
import { liquidateUnderwaterBorrowers } from './liquidateUnderwaterBorrowers';
import * as fs from 'fs';
import * as path from 'path';
const LOOP_DELAY = 5000; // 5 秒轮询间隔

/**
 * 清算机器人主循环
 */
async function main() {
  const network = hre.network.name;
  const chainId = hre.network.config.chainId;

  console.log('\n==========================================');
  console.log('🤖 YT Lending Liquidation Bot Started');
  console.log('==========================================');
  console.log('Network:', network);
  console.log('Chain ID:', chainId);
  console.log('Loop Delay:', LOOP_DELAY, 'ms\n');

  // 读取部署信息
  const deploymentsPath = path.join(__dirname, '../../deployments-lending.json');
  if (!fs.existsSync(deploymentsPath)) {
    throw new Error('deployments-lending.json not found');
  }

  const deployments = JSON.parse(fs.readFileSync(deploymentsPath, 'utf-8'));
  const deployment = deployments[chainId?.toString() || '421614'];

  if (!deployment) {
    throw new Error(`No deployment found for chainId: ${chainId}`);
  }

  console.log('📋 Contract Addresses:');
  console.log('  Lending Proxy:', deployment.lendingProxy);
  console.log('  Base Token (USDC):', deployment.usdcAddress);
  console.log('');

  // 获取签名者
  const [signer] = await hre.ethers.getSigners();
  console.log('👤 Liquidator Address:', await signer.getAddress());
  console.log('💰 Liquidator Balance:', hre.ethers.formatEther(await hre.ethers.provider.getBalance(signer)), 'ETH\n');

  // 初始化合约
  const lendingContract = await hre.ethers.getContractAt(
    'Lending',
    deployment.lendingProxy,
    signer
  );

  console.log('✅ Contracts initialized\n');
  console.log('==========================================');
  console.log('🔄 Starting main loop...\n');

  let lastBlockNumber: number | undefined;

  // while(true) 轮询
  while (true) {
    try {
      const currentBlockNumber = await hre.ethers.provider.getBlockNumber();

      console.log(`[${new Date().toISOString()}] Block: ${currentBlockNumber}`);

      // 检查是否有新区块（每个区块只处理一次）
      if (currentBlockNumber !== lastBlockNumber) {
        lastBlockNumber = currentBlockNumber;

        // 执行清算逻辑
        await liquidateUnderwaterBorrowers(
          lendingContract,
          signer
        );

        console.log(''); // 空行分隔
      } else {
        console.log(`Block already checked; waiting ${LOOP_DELAY}ms...\n`);
      }

      // 等待下一次轮询
      await new Promise(resolve => setTimeout(resolve, LOOP_DELAY));
    } catch (error) {
      console.error('❌ Error in main loop:', error);
      console.log(`Retrying in ${LOOP_DELAY}ms...\n`);
      await new Promise(resolve => setTimeout(resolve, LOOP_DELAY));
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Fatal error:', error);
    process.exit(1);
  });
