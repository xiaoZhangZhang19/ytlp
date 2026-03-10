// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./LendingStorage.sol";
import "./LendingMath.sol";
import "../interfaces/ILending.sol";
import "../interfaces/IYTLendingPriceFeed.sol";

/**
 * @title Lending
 * @notice 借贷池核心合约
 */
contract Lending is 
    ILending,
    LendingStorage,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化函数
     * @param config 市场配置
     */
    function initialize(Configuration calldata config) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        
        // 设置基础配置
        baseToken = config.baseToken;
        lendingPriceSource = config.lendingPriceSource;

        // 常量：一年的秒数
        uint64 SECONDS_PER_YEAR = 365 * 24 * 60 * 60;  // 31,536,000
        
        // 设置利率参数
        supplyKink = config.supplyKink;
        supplyPerSecondInterestRateSlopeLow = uint64(config.supplyPerYearInterestRateSlopeLow / SECONDS_PER_YEAR);
        supplyPerSecondInterestRateSlopeHigh = uint64(config.supplyPerYearInterestRateSlopeHigh / SECONDS_PER_YEAR);
        supplyPerSecondInterestRateBase = uint64(config.supplyPerYearInterestRateBase / SECONDS_PER_YEAR);
        
        borrowKink = config.borrowKink;
        borrowPerSecondInterestRateSlopeLow = uint64(config.borrowPerYearInterestRateSlopeLow / SECONDS_PER_YEAR);
        borrowPerSecondInterestRateSlopeHigh = uint64(config.borrowPerYearInterestRateSlopeHigh / SECONDS_PER_YEAR);
        borrowPerSecondInterestRateBase = uint64(config.borrowPerYearInterestRateBase / SECONDS_PER_YEAR);
        
        // 设置其他参数
        storeFrontPriceFactor = config.storeFrontPriceFactor;
        baseBorrowMin = config.baseBorrowMin;
        targetReserves = config.targetReserves;
        
        // 初始化利息累计因子
        supplyIndex = 1e18;
        borrowIndex = 1e18;
        lastAccrualTime = block.timestamp;
        
        // 设置抵押资产配置
        for (uint i = 0; i < config.assetConfigs.length; i++) {
            AssetConfig memory assetConfig = config.assetConfigs[i];
            
            // 验证参数合法性（必须 < 1）
            if(assetConfig.liquidationFactor >= 1e18) revert InvalidLiquidationFactor();
            if(assetConfig.borrowCollateralFactor >= 1e18) revert InvalidBorrowCollateralFactor();
            if(assetConfig.liquidateCollateralFactor >= 1e18) revert InvalidLiquidateCollateralFactor();
            
            assetConfigs[assetConfig.asset] = assetConfig;
            assetList.push(assetConfig.asset);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }

    function setTargetReserves(uint104 newTargetReserves) external onlyOwner {
        targetReserves = newTargetReserves;
        emit TargetReservesUpdated(targetReserves);
    }

    function setBaseBorrowMin(uint104 newBaseBorrowMin) external onlyOwner {
        baseBorrowMin = newBaseBorrowMin;
        emit BaseBorrowMinUpdated(baseBorrowMin);
    }

    /**
     * @notice 计算累计利息后的索引（不修改状态）
     * @param timeElapsed 经过的时间
     * @return 新的 supplyIndex 和 borrowIndex
     */
    function accruedInterestIndices(uint256 timeElapsed) internal view returns (uint256, uint256) {
        uint256 newSupplyIndex = supplyIndex;
        uint256 newBorrowIndex = borrowIndex;
        
        if (timeElapsed > 0) {
            // 计算实际的 totalSupply 和 totalBorrow（含利息）
            uint256 totalSupply = (uint256(totalSupplyBase) * supplyIndex) / 1e18;
            uint256 totalBorrow = (uint256(totalBorrowBase) * borrowIndex) / 1e18;
            
            uint64 utilization = LendingMath.getUtilization(totalSupply, totalBorrow);
            
            // 计算供应利率和借款利率（每秒利率）
            uint64 supplyRate = LendingMath.getSupplyRate(
                utilization,
                supplyKink,
                supplyPerSecondInterestRateSlopeLow,
                supplyPerSecondInterestRateSlopeHigh,
                supplyPerSecondInterestRateBase
            );
            
            uint64 borrowRate = LendingMath.getBorrowRate(
                utilization,
                borrowKink,
                borrowPerSecondInterestRateSlopeLow,
                borrowPerSecondInterestRateSlopeHigh,
                borrowPerSecondInterestRateBase
            );
            
            // 计算新的利息累计因子
            newSupplyIndex = LendingMath.accrueInterest(supplyIndex, supplyRate, timeElapsed);
            newBorrowIndex = LendingMath.accrueInterest(borrowIndex, borrowRate, timeElapsed);
        }
        
        return (newSupplyIndex, newBorrowIndex);
    }

    /**
     * @notice 计提利息
     */
    function accrueInterest() public {
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        if (timeElapsed == 0) return;
        
        // 使用辅助函数计算新索引
        (supplyIndex, borrowIndex) = accruedInterestIndices(timeElapsed);
        
        lastAccrualTime = block.timestamp;
    }

    /**
     * @notice 存入基础资产
     */
    function supply(uint256 amount) external override nonReentrant whenNotPaused {
        accrueInterest();
        
        IERC20(baseToken).transferFrom(msg.sender, address(this), amount);
        
        // 获取用户当前本金
        UserBasic memory user = userBasic[msg.sender];
        int104 oldPrincipal = user.principal;
        
        // 计算当前实际余额（含利息）
        uint256 index = oldPrincipal >= 0 ? supplyIndex : borrowIndex;
        int256 oldBalance = LendingMath.principalToBalance(oldPrincipal, index);
        
        // 计算新余额（增加存款）
        int256 newBalance = oldBalance + int256(amount);
        
        // 转换为新本金（可能从借款变为存款）
        uint256 newIndex = newBalance >= 0 ? supplyIndex : borrowIndex;
        int104 newPrincipal = LendingMath.balanceToPrincipal(newBalance, newIndex);
        
        // 根据新旧本金，计算还款和存款金额
        (uint104 repayAmount, uint104 supplyAmount) = LendingMath.repayAndSupplyAmount(oldPrincipal, newPrincipal);
        
        // 更新全局状态
        totalBorrowBase -= repayAmount;
        totalSupplyBase += supplyAmount;
        
        // 更新用户本金
        userBasic[msg.sender].principal = newPrincipal;
        
        emit Supply(msg.sender, msg.sender, amount);
    }

    /**
     * @notice 取出基础资产（如果余额不足会自动借款）
     * @dev 如果用户余额不足，会自动借款，借款金额为 amount，借款利率为 borrowRate，借款期限为 borrowPeriod
     */
    function withdraw(uint256 amount) external override nonReentrant whenNotPaused {
        accrueInterest();
        
        // 获取用户当前本金
        UserBasic memory user = userBasic[msg.sender];
        int104 oldPrincipal = user.principal;
        
        // 计算当前实际余额（含利息）
        uint256 index = oldPrincipal >= 0 ? supplyIndex : borrowIndex;
        int256 oldBalance = LendingMath.principalToBalance(oldPrincipal, index);
        
        // 计算新余额
        int256 newBalance = oldBalance - int256(amount);
        
        // 转换为新本金
        uint256 newIndex = newBalance >= 0 ? supplyIndex : borrowIndex;
        int104 newPrincipal = LendingMath.balanceToPrincipal(newBalance, newIndex);
        
        // 计算提取和借款金额
        (uint104 withdrawAmount, uint104 borrowAmount) = LendingMath.withdrawAndBorrowAmount(oldPrincipal, newPrincipal);
        
        // 更新全局状态
        totalSupplyBase -= withdrawAmount;
        totalBorrowBase += borrowAmount;
        
        // 更新用户本金
        userBasic[msg.sender].principal = newPrincipal;
        
        // 如果变成负余额（借款），检查抵押品
        if (newBalance < 0) {
            if (uint256(-newBalance) < baseBorrowMin) revert BorrowTooSmall();
            if (!_isSolvent(msg.sender)) revert InsufficientCollateral();
        }
        
        IERC20(baseToken).safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, msg.sender, amount);
    }

    /**
     * @notice 存入抵押品
     * @dev 由于不涉及债务计算，存入抵押品反而会让账户更安全，所以不用更新利息因子
     */
    function supplyCollateral(address asset, uint256 amount) external override nonReentrant whenNotPaused {
        AssetConfig memory config = assetConfigs[asset];
        if (config.asset == address(0)) revert Unauthorized();
        
        uint256 newTotal = userCollateral[msg.sender][asset] + amount;
        if (newTotal > config.supplyCap) revert SupplyCapExceeded();
        
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        
        userCollateral[msg.sender][asset] += amount;
        
        emit SupplyCollateral(msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice 取出抵押品
     */
    function withdrawCollateral(address asset, uint256 amount) external override nonReentrant whenNotPaused {
        accrueInterest();
        
        if (userCollateral[msg.sender][asset] < amount) revert InsufficientBalance();
        
        userCollateral[msg.sender][asset] -= amount;
        
        // 检查是否仍有足够的抵押品（如果有债务）
        int104 principal = userBasic[msg.sender].principal;
        if (principal < 0) {
            if (!_isSolvent(msg.sender)) revert InsufficientCollateral();
        }
        
        IERC20(asset).safeTransfer(msg.sender, amount);
        
        emit WithdrawCollateral(msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice 清算不良债务（内部实现）
     * @dev 当用户抵押品由于乘以liquidateCollateralFactor后，小于债务价值时，会进行清算，清算后，如果实际抵押品价值乘以liquidateCollateralFactor大于债务价值，则将差额部分作为用户本金（本金以baseToken显示），否则将差额部分作为坏账，由协议承担
     */
    function _absorbInternal(address absorber, address borrower) internal {
        if (!isLiquidatable(borrower)) revert NotLiquidatable();
        
        // 获取用户当前本金
        UserBasic memory user = userBasic[borrower];
        int104 oldPrincipal = user.principal;
        
        // 计算当前实际余额（含利息累计的债务）
        int256 oldBalance = LendingMath.principalToBalance(oldPrincipal, borrowIndex);
        if (oldBalance >= 0) revert NotLiquidatable();
        
        // 计算所有抵押品的总价值（按 liquidationFactor 折扣）
        uint256 basePrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(baseToken);
        uint256 totalCollateralValue = 0;
        
        for (uint i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            uint256 collateralAmount = userCollateral[borrower][asset];
            
            if (collateralAmount > 0) {
                AssetConfig memory assetConfig = assetConfigs[asset];
                uint256 assetPrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(asset);
                
                // 计算抵押品价值-用于事件记录
                uint256 assetScale = 10 ** assetConfig.decimals;
                uint256 collateralValueUSD = (collateralAmount * assetPrice) / assetScale;
                
                // 直接计算折扣后的价值，避免二次除法
                // discounted = (amount * price * factor) / (scale * 1e18)
                uint256 discountedValue = (collateralAmount * assetPrice * assetConfig.liquidationFactor) / (assetScale * 1e18);
                totalCollateralValue += discountedValue;
                
                // 将抵押品转移到清算库存
                userCollateral[borrower][asset] = 0;
                collateralReserves[asset] += collateralAmount;
                
                // 发射抵押品吸收事件
                emit AbsorbCollateral(absorber, borrower, asset, collateralAmount, collateralValueUSD);
            }
        }
        
        // 将抵押品价值转换为 baseToken 数量
        uint256 baseScale = 10 ** IERC20Metadata(baseToken).decimals();
        uint256 collateralInBase = (totalCollateralValue * baseScale) / basePrice;
        
        // 计算新余额：oldBalance（负数）+ 抵押品价值
        int256 newBalance = oldBalance + int256(collateralInBase);
        
        // 如果新余额仍为负，强制归零（坏账由协议承担）
        if (newBalance < 0) {
            newBalance = 0;
        }
        
        // 转换为新本金
        int104 newPrincipal = LendingMath.balanceToPrincipal(newBalance, supplyIndex);
        
        // 更新用户本金
        userBasic[borrower].principal = newPrincipal;
        
        // 计算偿还和供应金额
        (uint104 repayAmount, uint104 supplyAmount) = LendingMath.repayAndSupplyAmount(oldPrincipal, newPrincipal);
        
        // 更新全局状态（储备金通过减少 totalBorrowBase 和增加 totalSupplyBase 来承担坏账）
        totalSupplyBase += supplyAmount;
        totalBorrowBase -= repayAmount;
        
        // 计算协议承担的坏账部分
        // 坏账 = 用户债务 - 抵押品价值（当抵押品不足时）
        uint256 basePaidOut = 0;
        if (int256(collateralInBase) < -oldBalance) {
            // 抵押品不足以覆盖债务，差额由协议储备金承担
            basePaidOut = uint256(-oldBalance) - collateralInBase;
        }
        // 如果 collateralInBase >= -oldBalance，说明抵押品足够，无坏账
        
        uint256 valueOfBasePaidOut = (basePaidOut * basePrice) / baseScale;
        
        // 发射债务吸收事件
        emit AbsorbDebt(absorber, borrower, basePaidOut, valueOfBasePaidOut);
    }
    
    /**
     * @notice 清算不良债务（单个）
     */
    function absorb(address borrower) external override nonReentrant whenNotPaused {
        accrueInterest();
        _absorbInternal(msg.sender, borrower);
    }
    
    /**
     * @notice 批量清算不良债务
     */
    function absorbMultiple(address absorber, address[] calldata accounts) external override nonReentrant whenNotPaused {
        accrueInterest();
        for (uint i = 0; i < accounts.length; ) {
            _absorbInternal(absorber, accounts[i]);
            unchecked { i++; }
        }
    }

    /**
     * @notice 购买清算后的抵押品
     * @dev 自动限制购买量到可用储备，只收取实际需要的费用
     */
    function buyCollateral(
        address asset,
        uint256 minAmount,
        uint256 baseAmount,
        address recipient
    ) external override nonReentrant whenNotPaused {
        if (collateralReserves[asset] == 0) revert InsufficientBalance();
        
        // 检查储备金是否充足（使用实时计算的储备金）
        int256 currentReserves = getReserves();
        if (currentReserves >= 0 && uint256(currentReserves) >= targetReserves) {
            revert NotForSale(); // 储备金充足，无需出售
        }
        
        // 计算可购买的抵押品数量（基于用户愿意支付的 baseAmount）
        uint256 collateralAmount = quoteCollateral(asset, baseAmount);
        
        // 自动限制到可用储备量
        // 这样可以防止价格波动导致交易失败
        if (collateralAmount > collateralReserves[asset]) {
            collateralAmount = collateralReserves[asset];
        }
        
        // 滑点保护：确保购买量不低于用户的最小期望
        if (collateralAmount < minAmount) revert InsufficientBalance();
        
        // 根据实际购买量计算需要支付的金额（而非固定的 baseAmount）
        // 这样如果购买量被限制，用户只需支付相应的费用
        uint256 actualBaseAmount = quoteBaseAmount(asset, collateralAmount);
        
        // 收取实际需要的资金
        IERC20(baseToken).transferFrom(msg.sender, address(this), actualBaseAmount);
        
        // 抵押品出库
        collateralReserves[asset] -= collateralAmount;
        
        // 转账抵押品到指定接收人
        IERC20(asset).safeTransfer(recipient, collateralAmount);
        
        // 注意：收入会自动体现在 getReserves() 中，因为 balance 增加了
        emit BuyCollateral(msg.sender, asset, actualBaseAmount, collateralAmount);
    }
    
    /**
     * @notice 计算购买指定数量抵押品需要支付的 baseToken 数量（反向计算）
     * @param asset 抵押品地址
     * @param collateralAmount 要购买的抵押品数量
     * @return 需要支付的 baseToken 数量
     */
    function quoteBaseAmount(address asset, uint256 collateralAmount) internal view returns (uint256) {
        AssetConfig memory assetConfig = assetConfigs[asset];
        
        uint256 assetPrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(asset);
        uint256 basePrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(baseToken);
        
        uint256 FACTOR_SCALE = 1e18;
        uint256 baseScale = 10 ** uint256(IERC20Metadata(baseToken).decimals());
        uint256 assetScale = 10 ** uint256(assetConfig.decimals);
        
        // 计算折扣因子
        uint256 discountFactor = (storeFrontPriceFactor * (FACTOR_SCALE - assetConfig.liquidationFactor)) / FACTOR_SCALE;
        
        // 计算折扣后的资产价格
        uint256 effectiveAssetPrice = (assetPrice * (FACTOR_SCALE - discountFactor)) / FACTOR_SCALE;
        
        // 反向计算：baseAmount = (collateralAmount * effectiveAssetPrice * baseScale) / (basePrice * assetScale)
        if (baseScale == assetScale) {
            return (collateralAmount * effectiveAssetPrice) / basePrice;
        } else {
            uint256 adjustedAmount = (collateralAmount * baseScale) / assetScale;
            return (adjustedAmount * effectiveAssetPrice) / basePrice;
        }
    }
    
    /**
     * @notice 计算支付指定baseAmount可购买的抵押品数量
     * @dev 重新设计以避免在 1e30 价格精度下溢出
     */
    function quoteCollateral(address asset, uint256 baseAmount) public view override returns (uint256) {
        AssetConfig memory assetConfig = assetConfigs[asset];
        
        uint256 assetPrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(asset);
        uint256 basePrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(baseToken);
        
        uint256 FACTOR_SCALE = 1e18;
        uint256 baseScale = 10 ** uint256(IERC20Metadata(baseToken).decimals());
        uint256 assetScale = 10 ** uint256(assetConfig.decimals);
        
        // 计算折扣因子
        uint256 discountFactor = (storeFrontPriceFactor * (FACTOR_SCALE - assetConfig.liquidationFactor)) / FACTOR_SCALE;
        
        // 计算折扣后的资产价格 (保持 1e30 精度)
        uint256 effectiveAssetPrice = (assetPrice * (FACTOR_SCALE - discountFactor)) / FACTOR_SCALE;
        
        // 为了避免溢出，我们需要重新排列计算:
        // result = (basePrice * baseAmount * assetScale) / (effectiveAssetPrice * baseScale)
        // 
        // 由于所有价格都是 1e30 精度，我们可以先约简价格:
        // priceRatio = basePrice / effectiveAssetPrice (保持精度)
        // result = (baseAmount * priceRatio * assetScale) / (1e30 * baseScale)
        //
        // 但为了避免精度损失，我们分步计算:
        // step1 = baseAmount * assetScale / baseScale  (token amount conversion)
        // step2 = step1 * basePrice / effectiveAssetPrice  (price conversion)
        
        // 如果 baseScale 和 assetScale 相同(都是18)，可以简化
        if (baseScale == assetScale) {
            // result = baseAmount * basePrice / effectiveAssetPrice
            return (baseAmount * basePrice) / effectiveAssetPrice;
        } else {
            // 一般情况：分步计算避免溢出
            uint256 adjustedAmount = (baseAmount * assetScale) / baseScale;
            return (adjustedAmount * basePrice) / effectiveAssetPrice;
        }
    }

    /**
     * @notice 检查账户偿付能力
     */
    function _isSolvent(address account) internal view returns (bool) {
        int104 principal = userBasic[account].principal;
        if (principal >= 0) return true;
        
        // 计算实际债务（含利息）- 使用 borrowIndex
        int256 balance = LendingMath.principalToBalance(principal, borrowIndex);
        uint256 debt = uint256(-balance);
        
        // 将 debt 转换为美元价值（使用 baseToken 价格）
        uint256 basePrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(baseToken);
        uint256 baseDecimals = IERC20Metadata(baseToken).decimals();
        uint256 debtValue = (debt * basePrice) / (10 ** baseDecimals);
        
        // 计算借款能力（抵押品价值已经在 _getCollateralValue 中应用了借款系数）
        uint256 borrowCapacity = _getCollateralValue(account);
        
        // 比较：借款能力 >= 债务价值
        return borrowCapacity >= debtValue;
    }

    /**
     * @notice 计算账户抵押品总价值
     */
    function _getCollateralValue(address account) internal view returns (uint256) {
        uint256 totalValue = 0;
        
        for (uint i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            uint256 amount = userCollateral[account][asset];
            if (amount > 0) {
                AssetConfig memory config = assetConfigs[asset];
                uint256 price = IYTLendingPriceFeed(lendingPriceSource).getPrice(asset);
                uint256 value = LendingMath.getCollateralValue(amount, price, config.decimals);
                totalValue += (value * config.borrowCollateralFactor) / 1e18;
            }
        }
        
        return totalValue;
    }

    // ========== View Functions ==========

    function getBalance(address account) external view override returns (int256) {
        int104 principal = userBasic[account].principal;
        // 根据余额正负使用对应的索引：正余额用supplyIndex，负余额用borrowIndex
        uint256 index = principal >= 0 ? supplyIndex : borrowIndex;
        return LendingMath.principalToBalance(principal, index);
    }
    
    function supplyBalanceOf(address account) external view override returns (uint256) {
        int104 principal = userBasic[account].principal;
        if (principal <= 0) return 0;
        // 只返回正余额（存款）
        return uint256(LendingMath.principalToBalance(principal, supplyIndex));
    }
    
    function borrowBalanceOf(address account) external view override returns (uint256) {
        int104 principal = userBasic[account].principal;
        if (principal >= 0) return 0;
        // 只返回负余额（借款），转为正数
        int256 balance = LendingMath.principalToBalance(principal, borrowIndex);
        return uint256(-balance);
    }

    function getCollateral(address account, address asset) external view override returns (uint256) {
        return userCollateral[account][asset];
    }

    function isLiquidatable(address account) public view override returns (bool) {
        int104 principal = userBasic[account].principal;
        if (principal >= 0) return false;
        
        // 计算实际债务（含利息）
        int256 balance = LendingMath.principalToBalance(principal, borrowIndex);
        uint256 debt = uint256(-balance);
        
        // 将 debt 转换为美元价值（使用 baseToken 价格和 price feed 精度）
        uint256 basePrice = IYTLendingPriceFeed(lendingPriceSource).getPrice(baseToken);
        uint256 baseDecimals = IERC20Metadata(baseToken).decimals();
        uint256 debtValue = (debt * basePrice) / (10 ** baseDecimals);
        
        // 计算抵押品总价值（清算阈值）
        uint256 collateralValue = 0;
        for (uint i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            uint256 amount = userCollateral[account][asset];
            if (amount > 0) {
                AssetConfig memory config = assetConfigs[asset];
                uint256 price = IYTLendingPriceFeed(lendingPriceSource).getPrice(asset);
                uint256 value = LendingMath.getCollateralValue(amount, price, config.decimals);
                collateralValue += (value * config.liquidateCollateralFactor) / 1e18;
            }
        }
        
        // 比较：债务价值 > 抵押品清算阈值价值
        return debtValue > collateralValue;
    }

    function getTotalSupply() external view returns (uint256) {
        return (uint256(totalSupplyBase) * supplyIndex) / 1e18;
    }
    
    function getTotalBorrow() external view returns (uint256) {
        return (uint256(totalBorrowBase) * borrowIndex) / 1e18;
    }
    
    function getCollateralReserves(address asset) external view override returns (uint256) {
        return collateralReserves[asset];
    }
    
    function getReserves() public view override returns (int256) {
        // 计算最新的利息索引（不修改状态）
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        (uint256 newSupplyIndex, uint256 newBorrowIndex) = accruedInterestIndices(timeElapsed);
        
        // 使用最新索引计算实际总供应和总借款（含利息）
        uint256 balance = IERC20(baseToken).balanceOf(address(this));
        uint256 totalSupply = (uint256(totalSupplyBase) * newSupplyIndex) / 1e18;
        uint256 totalBorrow = (uint256(totalBorrowBase) * newBorrowIndex) / 1e18;
        
        // reserves = balance - totalSupply + totalBorrow
        return int256(balance) - int256(totalSupply) + int256(totalBorrow);
    }
    
    function getUtilization() external view override returns (uint256) {
        uint256 totalSupply = (uint256(totalSupplyBase) * supplyIndex) / 1e18;
        uint256 totalBorrow = (uint256(totalBorrowBase) * borrowIndex) / 1e18;
        return LendingMath.getUtilization(totalSupply, totalBorrow);
    }
    
    function getSupplyRate() external view override returns (uint64) {
        uint256 totalSupply = (uint256(totalSupplyBase) * supplyIndex) / 1e18;
        uint256 totalBorrow = (uint256(totalBorrowBase) * borrowIndex) / 1e18;
        uint64 utilization = LendingMath.getUtilization(totalSupply, totalBorrow);
        uint64 perSecondRate = LendingMath.getSupplyRate(
            utilization,
            supplyKink,
            supplyPerSecondInterestRateSlopeLow,
            supplyPerSecondInterestRateSlopeHigh,
            supplyPerSecondInterestRateBase
        );
        //（APR）
        return perSecondRate * 31536000; // SECONDS_PER_YEAR
    }

    function getBorrowRate() external view override returns (uint64) {
        uint256 totalSupply = (uint256(totalSupplyBase) * supplyIndex) / 1e18;
        uint256 totalBorrow = (uint256(totalBorrowBase) * borrowIndex) / 1e18;
        uint64 utilization = LendingMath.getUtilization(totalSupply, totalBorrow);
        uint64 perSecondRate = LendingMath.getBorrowRate(
            utilization,
            borrowKink,
            borrowPerSecondInterestRateSlopeLow,
            borrowPerSecondInterestRateSlopeHigh,
            borrowPerSecondInterestRateBase
        );
        //（APR）
        return perSecondRate * 31536000; // SECONDS_PER_YEAR
    }

    /**
     * @notice 提取协议储备金（仅 owner）
     */
    function withdrawReserves(address to, uint256 amount) external override onlyOwner nonReentrant {
        // 使用实时计算的储备金
        int256 currentReserves = getReserves();
        
        // 检查储备金是否充足
        if (currentReserves < 0 || amount > uint256(currentReserves)) {
            revert InsufficientReserves();
        }
        
        // 转账储备金
        IERC20(baseToken).safeTransfer(to, amount);
        
        emit WithdrawReserves(to, amount);
    }

    /**
     * @dev 预留存储空间，用于未来升级时添加新的状态变量
     * 50个slot = 50 * 32 bytes = 1600 bytes
     */
    uint256[50] private __gap;
}