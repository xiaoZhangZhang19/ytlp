// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title LendingMath
 * @notice 借贷池数学计算库
 */
library LendingMath {
    uint256 internal constant FACTOR_SCALE = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

    /**
     * @notice 将本金转换为实际余额（含利息）
     * @param principal 本金（正数或负数）
     * @param index 利息索引
     * @return 实际余额
     */
    function principalToBalance(int104 principal, uint256 index) internal pure returns (int256) {
        return int256(principal) * int256(index) / int256(FACTOR_SCALE);
    }
    
    /**
     * @notice 将实际余额转换为本金
     * @param balance 实际余额（正数或负数）
     * @param index 利息索引
     * @return 本金
     */
    function balanceToPrincipal(int256 balance, uint256 index) internal pure returns (int104) {
        return int104((balance * int256(FACTOR_SCALE)) / int256(index));
    }
    
    /**
     * @notice 计算供应方本金变化和借款方本金变化
     * @dev 用于 absorb 时计算账户状态变化
     */
    function repayAndSupplyAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // 如果新本金小于旧本金，没有偿还或供应
        if (newPrincipal < oldPrincipal) return (0, 0);
        
        if (newPrincipal <= 0) {
            // 从负数变得更接近0（偿还债务）
            return (uint104(newPrincipal - oldPrincipal), 0);
        } else if (oldPrincipal >= 0) {
            // 两个都是正数（增加存款）
            return (0, uint104(newPrincipal - oldPrincipal));
        } else {
            // 从负数变正数（偿还所有债务并存款）
            return (uint104(-oldPrincipal), uint104(newPrincipal));
        }
    }
    
    /**
     * @notice 计算提取金额和借款金额
     * @dev 用于 withdraw/borrow 时计算账户状态变化
     */
    function withdrawAndBorrowAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // 如果新本金大于旧本金，没有提取或借款
        if (newPrincipal > oldPrincipal) return (0, 0);
        
        if (newPrincipal >= 0) {
            // 还是正数（提取存款）
            return (uint104(oldPrincipal - newPrincipal), 0);
        } else if (oldPrincipal <= 0) {
            // 两个都是负数（增加借款）
            return (0, uint104(oldPrincipal - newPrincipal));
        } else {
            // 从正数变负数（提取所有存款并借款）
            return (uint104(oldPrincipal), uint104(-newPrincipal));
        }
    }

    /**
     * @notice 计算利用率
     * @param totalSupply 总供应量
     * @param totalBorrow 总借款量
     * @return 利用率 (scaled by 1e18)
     */
    function getUtilization(uint256 totalSupply, uint256 totalBorrow) internal pure returns (uint64) {
        if (totalSupply == 0) return 0;
        return uint64((totalBorrow * FACTOR_SCALE) / totalSupply);
    }

    /**
     * @notice 计算供应利率（每秒利率）
     */
    function getSupplyRate(
        uint256 utilization,
        uint64 supplyKink,
        uint64 supplyPerSecondInterestRateSlopeLow,
        uint64 supplyPerSecondInterestRateSlopeHigh,
        uint64 supplyPerSecondInterestRateBase
    ) internal pure returns (uint64) {
        if (utilization <= supplyKink) {
            return supplyPerSecondInterestRateBase + uint64((utilization * supplyPerSecondInterestRateSlopeLow) / FACTOR_SCALE);
        } else {
            uint256 excessUtil = utilization - supplyKink;
            return supplyPerSecondInterestRateBase + supplyPerSecondInterestRateSlopeLow + 
                   uint64((excessUtil * supplyPerSecondInterestRateSlopeHigh) / FACTOR_SCALE);
        }
    }

    /**
     * @notice 计算借款利率（每秒利率）
     */
    function getBorrowRate(
        uint256 utilization,
        uint64 borrowKink,
        uint64 borrowPerSecondInterestRateSlopeLow,
        uint64 borrowPerSecondInterestRateSlopeHigh,
        uint64 borrowPerSecondInterestRateBase
    ) internal pure returns (uint64) {
        if (utilization <= borrowKink) {
            return borrowPerSecondInterestRateBase + uint64((utilization * borrowPerSecondInterestRateSlopeLow) / FACTOR_SCALE);
        } else {
            uint256 excessUtil = utilization - borrowKink;
            return borrowPerSecondInterestRateBase + borrowPerSecondInterestRateSlopeLow + 
                   uint64((excessUtil * borrowPerSecondInterestRateSlopeHigh) / FACTOR_SCALE);
        }
    }

    /**
     * @notice 计算复利后的利息累计因子
     * @param index 当前利息累计因子
     * @param interestRatePerSecond 每秒利率
     * @param timeElapsed 经过的秒数
     * @return 新的利息累计因子
     */
    function accrueInterest(
        uint256 index,
        uint64 interestRatePerSecond,
        uint256 timeElapsed
    ) internal pure returns (uint256) {
        // 优化：每秒利率直接乘以时间，只需一次除法
        uint256 interestAccrued = (index * interestRatePerSecond * timeElapsed) / FACTOR_SCALE;
        return index + interestAccrued;
    }

    /**
     * @notice 计算抵押品价值
     */
    function getCollateralValue(
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint8 collateralDecimals
    ) internal pure returns (uint256) {
        return (collateralAmount * collateralPrice) / (10 ** collateralDecimals);
    }

    /**
     * @notice 计算借款能力
     */
    function getBorrowCapacity(
        uint256 collateralValue,
        uint64 borrowCollateralFactor
    ) internal pure returns (uint256) {
        return (collateralValue * borrowCollateralFactor) / FACTOR_SCALE;
    }
}

