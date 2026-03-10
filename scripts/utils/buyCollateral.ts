import { ethers } from "hardhat";
import { Lending } from "../../typechain-types";

/**
 * 购买清算抵押品脚本
 *
 * 自动扫描合约中所有抵押品资产，对有储备的资产执行购买。
 * 传入买家当前余额作为 baseAmount 上限，合约自动按实际储备量收费。
 * 无需指定具体资产地址，脚本会自动遍历合约的 assetList。
 *
 * 环境变量:
 * - LENDING_ADDRESS: Lending 合约地址（必填）
 * - SLIPPAGE (可选): 滑点容忍度百分比 (1-5)，默认 1
 */
async function main() {
  // ==================== 配置 ====================
  const LENDING_ADDRESS = process.env.LENDING_ADDRESS;
  const SLIPPAGE_PERCENT = parseFloat(process.env.SLIPPAGE || "1");

  if (!LENDING_ADDRESS || LENDING_ADDRESS === "0x...") {
    throw new Error("请设置 LENDING_ADDRESS 环境变量");
  }
  if (SLIPPAGE_PERCENT < 0 || SLIPPAGE_PERCENT > 10) {
    throw new Error("SLIPPAGE 应在 0-10 之间");
  }

  const SLIPPAGE = SLIPPAGE_PERCENT / 100;

  console.log("==================== 购买清算抵押品 ====================");
  console.log(`Lending 合约: ${LENDING_ADDRESS}`);
  console.log(`滑点容忍度: ${SLIPPAGE_PERCENT}%`);
  console.log("");

  // ==================== 初始化 ====================
  const lending = await ethers.getContractAt("Lending", LENDING_ADDRESS) as unknown as Lending;
  const [buyer] = await ethers.getSigners();
  const baseToken = await lending.baseToken();
  const base = await ethers.getContractAt("IERC20Metadata", baseToken);
  const baseDecimals = await base.decimals();

  console.log(`买家地址: ${buyer.address}`);

  // ==================== 系统状态检查 ====================
  console.log("\n检查系统状态...");
  const reserves = await lending.getReserves();
  const targetReserves = await lending.targetReserves();
  console.log(`当前储备金: ${ethers.formatUnits(reserves, baseDecimals)} baseToken`);
  console.log(`目标储备金: ${ethers.formatUnits(targetReserves, baseDecimals)} baseToken`);

  if (reserves >= 0n && BigInt(reserves.toString()) >= targetReserves) {
    throw new Error("储备金充足，当前无法购买抵押品");
  }

  // ==================== 扫描可购买资产 ====================
  const assetsToProcess = await getAllAssets(lending);
  console.log(`\n发现 ${assetsToProcess.length} 个抵押品资产`);

  // 过滤出有储备的资产
  const assetsWithReserves: { address: string; reserve: bigint; decimals: number }[] = [];
  for (const assetAddr of assetsToProcess) {
    const reserve = await lending.getCollateralReserves(assetAddr);
    if (reserve > 0n) {
      const assetToken = await ethers.getContractAt("IERC20Metadata", assetAddr);
      const dec = await assetToken.decimals();
      assetsWithReserves.push({ address: assetAddr, reserve, decimals: dec });
      console.log(`  ${assetAddr}: 储备 ${ethers.formatUnits(reserve, dec)} 代币`);
    }
  }

  if (assetsWithReserves.length === 0) {
    console.log("\n所有资产储备均为零，无需购买。");
    return;
  }

  // ==================== 授权（一次性 MaxUint256）====================
  console.log("\n检查授权...");
  const allowance = await base.allowance(buyer.address, LENDING_ADDRESS);
  if (allowance < ethers.MaxUint256 / 2n) {
    console.log("正在授权 MaxUint256...");
    const approveTx = await base.approve(LENDING_ADDRESS, ethers.MaxUint256);
    await approveTx.wait();
    console.log("授权成功");
  } else {
    console.log("授权充足，无需重复授权");
  }

  // ==================== 逐资产购买 ====================
  let totalPaid = 0n;
  let successCount = 0;

  for (const { address: assetAddr, reserve, decimals: assetDecimals } of assetsWithReserves) {
    console.log(`\n---- 购买资产: ${assetAddr} ----`);

    // 读取买家当前余额作为本次最大支付额
    const buyerBalance = await base.balanceOf(buyer.address);
    if (buyerBalance === 0n) {
      console.log("买家余额已耗尽，跳过剩余资产");
      break;
    }
    console.log(`买家当前余额: ${ethers.formatUnits(buyerBalance, baseDecimals)} baseToken`);
    console.log(`可用储备: ${ethers.formatUnits(reserve, assetDecimals)} 代币`);

    // minAmount = 储备量 * (1 - slippage)，允许价格轻微偏移
    const slippageMultiplier = BigInt(Math.floor((1 - SLIPPAGE) * 1e18));
    const minAmount = (reserve * slippageMultiplier) / BigInt(1e18);
    console.log(`最小接受量 (${SLIPPAGE_PERCENT}% 滑点): ${ethers.formatUnits(minAmount, assetDecimals)} 代币`);

    // 以买家全部余额作为 baseAmount 上限；合约内部按实际储备量收费
    try {
      const tx = await lending.buyCollateral(
        assetAddr,
        minAmount,
        buyerBalance,
        buyer.address
      );
      console.log(`交易已提交: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`交易确认，Gas 消耗: ${receipt?.gasUsed.toString()}`);

      // 解析事件
      const buyEvent = receipt?.logs.find((log: any) => {
        try { return lending.interface.parseLog(log)?.name === "BuyCollateral"; }
        catch { return false; }
      });

      if (buyEvent) {
        const parsed = lending.interface.parseLog(buyEvent);
        const paidAmount: bigint = parsed?.args.baseAmount;
        const receivedAmount: bigint = parsed?.args.collateralAmount;
        totalPaid += paidAmount;
        successCount++;

        console.log(`实际支付: ${ethers.formatUnits(paidAmount, baseDecimals)} baseToken`);
        console.log(`实际获得: ${ethers.formatUnits(receivedAmount, assetDecimals)} 代币`);

        // 折扣信息
        const marketAmount = await lending.quoteCollateral(assetAddr, paidAmount);
        if (receivedAmount > marketAmount && marketAmount > 0n) {
          const discount = ((receivedAmount - marketAmount) * 10000n) / marketAmount;
          console.log(`折扣收益: +${ethers.formatUnits(receivedAmount - marketAmount, assetDecimals)} 代币 (${Number(discount) / 100}%)`);
        }
      }
    } catch (err: any) {
      console.log(`跳过 ${assetAddr}：${err.message?.split("\n")[0] ?? err}`);
    }
  }

  // ==================== 汇总 ====================
  console.log("\n==================== 购买汇总 ====================");
  console.log(`成功购买资产数: ${successCount} / ${assetsWithReserves.length}`);
  console.log(`累计支付: ${ethers.formatUnits(totalPaid, baseDecimals)} baseToken`);

  const finalBalance = await base.balanceOf(buyer.address);
  console.log(`买家剩余余额: ${ethers.formatUnits(finalBalance, baseDecimals)} baseToken`);
  console.log("===================================================");
}

/**
 * 遍历合约 assetList 数组，获取所有抵押品地址
 */
async function getAllAssets(lending: Lending): Promise<string[]> {
  const assets: string[] = [];
  let i = 0;
  while (true) {
    try {
      const asset = await (lending as any).assetList(i);
      assets.push(asset);
      i++;
    } catch {
      break; // 数组越界，遍历结束
    }
  }
  return assets;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n执行失败:", error.message || error);
    process.exit(1);
  });

/**
 * 获取单个资产的购买详情（供外部调用）
 */
export async function getBuyCollateralInfo(
  lendingContract: Lending,
  asset: string,
  baseAmount: bigint,
  slippageTolerance: number = 0.01
) {
  const availableReserve = await lendingContract.getCollateralReserves(asset);
  // minAmount 基于实际储备量而非 quote，允许 slippage 偏移
  const slippageMultiplier = BigInt(Math.floor((1 - slippageTolerance) * 1e18));
  const minAmount = (availableReserve * slippageMultiplier) / BigInt(1e18);

  // 用于展示：预估 baseAmount 能买到多少（可能超过储备，合约会自动限制）
  const expectedAmount = await lendingContract.quoteCollateral(asset, baseAmount);
  const actualAmount = expectedAmount < availableReserve ? expectedAmount : availableReserve;
  const actualBaseAmount = actualAmount < expectedAmount
    ? (baseAmount * actualAmount) / expectedAmount
    : baseAmount;

  return {
    availableReserve,
    expectedAmount,
    actualAmount,
    minAmount,
    baseAmount,
    actualBaseAmount,
    isLimited: actualAmount < expectedAmount,
  };
}