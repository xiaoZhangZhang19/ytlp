import hre from 'hardhat';
import { Signer } from 'ethers';

const LOOKBACK_BLOCKS = 10000; // 查询最近 50000 个区块

/**
 * 获取最近活跃的地址（通过多个事件）
 */
export async function getUniqueAddresses(
  lendingContract: any
): Promise<string[]> {
  const currentBlock = await hre.ethers.provider.getBlockNumber();
  const fromBlock = Math.max(currentBlock - LOOKBACK_BLOCKS, 0);

  console.log(`📊 Querying events from block ${fromBlock} to ${currentBlock}...`);

  const uniqueAddresses = new Set<string>();

  // 1. Withdraw 事件（借款/提现）
  try {
    const withdrawFilter = lendingContract.filters.Withdraw();
    const withdrawEvents = await lendingContract.queryFilter(
      withdrawFilter,
      fromBlock,
      currentBlock
    );
    for (const event of withdrawEvents) {
      if (event.args?.src) uniqueAddresses.add(event.args.src);
      if (event.args?.dst) uniqueAddresses.add(event.args.dst);
    }
    console.log(`  - Withdraw events: ${withdrawEvents.length}`);
  } catch (error) {
    console.error('  ⚠️  Failed to query Withdraw events:', error);
  }

  // 2. Supply 事件（存款）
  try {
    const supplyFilter = lendingContract.filters.Supply();
    const supplyEvents = await lendingContract.queryFilter(
      supplyFilter,
      fromBlock,
      currentBlock
    );
    for (const event of supplyEvents) {
      if (event.args?.from) uniqueAddresses.add(event.args.from);
      if (event.args?.dst) uniqueAddresses.add(event.args.dst);
    }
    console.log(`  - Supply events: ${supplyEvents.length}`);
  } catch (error) {
    console.error('  ⚠️  Failed to query Supply events:', error);
  }

  // 3. SupplyCollateral 事件（抵押品存入）
  try {
    const supplyCollateralFilter = lendingContract.filters.SupplyCollateral();
    const supplyCollateralEvents = await lendingContract.queryFilter(
      supplyCollateralFilter,
      fromBlock,
      currentBlock
    );
    for (const event of supplyCollateralEvents) {
      if (event.args?.from) uniqueAddresses.add(event.args.from);
      if (event.args?.dst) uniqueAddresses.add(event.args.dst);
    }
    console.log(`  - SupplyCollateral events: ${supplyCollateralEvents.length}`);
  } catch (error) {
    console.error('  ⚠️  Failed to query SupplyCollateral events:', error);
  }

  // 4. WithdrawCollateral 事件（抵押品提取）
  try {
    const withdrawCollateralFilter = lendingContract.filters.WithdrawCollateral();
    const withdrawCollateralEvents = await lendingContract.queryFilter(
      withdrawCollateralFilter,
      fromBlock,
      currentBlock
    );
    for (const event of withdrawCollateralEvents) {
      if (event.args?.src) uniqueAddresses.add(event.args.src);
      if (event.args?.to) uniqueAddresses.add(event.args.to);
    }
    console.log(`  - WithdrawCollateral events: ${withdrawCollateralEvents.length}`);
  } catch (error) {
    console.error('  ⚠️  Failed to query WithdrawCollateral events:', error);
  }

  console.log(`✅ Found ${uniqueAddresses.size} unique addresses from all events`);
  return Array.from(uniqueAddresses);
}

/**
 * 检查并清算可清算账户
 */
export async function liquidateUnderwaterBorrowers(
  lendingContract: any,
  signer: Signer
): Promise<boolean> {
  // 步骤 1: 获取最近活跃的地址
  const uniqueAddresses = await getUniqueAddresses(lendingContract);

  if (uniqueAddresses.length === 0) {
    console.log('ℹ️  No active addresses found');
    return false;
  }

  console.log(`🔍 Checking ${uniqueAddresses.length} addresses for liquidation...`);

  const liquidatableAccounts: string[] = [];

  // 步骤 2: 检查每个地址是否可清算
  for (const address of uniqueAddresses) {
    try {
      // 直接调用合约的 isLiquidatable()，无需自己计算健康因子
      const isLiquidatable = await lendingContract.isLiquidatable(address);

      if (isLiquidatable) {
        console.log(`💰 Liquidatable: ${address}`);
        liquidatableAccounts.push(address);
      }
    } catch (error) {
      console.error(`Error checking ${address}:`, error);
    }
  }

  // 步骤 3: 批量清算
  if (liquidatableAccounts.length > 0) {
    console.log(`\n🎯 Found ${liquidatableAccounts.length} liquidatable accounts`);
    console.log('📤 Sending liquidation transaction...');

    try {
      const liquidatorAddress = await signer.getAddress();
      const tx = await lendingContract.connect(signer).absorbMultiple(
        liquidatorAddress,
        liquidatableAccounts
      );

      console.log(`🔗 Transaction sent: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`✅ Liquidation successful!`);
      console.log(`   Gas used: ${receipt.gasUsed.toString()}`);
      console.log(`   Block: ${receipt.blockNumber}`);

      return true;
    } catch (error) {
      console.error('❌ Liquidation transaction failed:', error);
      return false;
    }
  } else {
    console.log('✅ No liquidatable accounts found');
    return false;
  }
}