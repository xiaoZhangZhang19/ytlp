// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ILending
 * @notice 借贷池核心接口
 */
interface ILending {
    event Supply(address indexed from, address indexed dst, uint256 amount);
    event Withdraw(address indexed src, address indexed to, uint256 amount);
    event SupplyCollateral(address indexed from, address indexed dst, address indexed asset, uint256 amount);
    event WithdrawCollateral(address indexed src, address indexed to, address indexed asset, uint256 amount);
    event AbsorbDebt(address indexed absorber, address indexed borrower, uint256 basePaidOut, uint256 usdValue);
    event AbsorbCollateral(address indexed absorber, address indexed borrower, address indexed asset, uint256 collateralAbsorbed, uint256 usdValue);
    event BuyCollateral(address indexed buyer, address indexed asset, uint256 baseAmount, uint256 collateralAmount);
    event WithdrawReserves(address indexed to, uint256 amount);
    event TargetReservesUpdated(uint104 targetReserves);
    event BaseBorrowMinUpdated(uint104 baseBorrowMin);
    
    error Unauthorized();
    error InsufficientBalance();
    error InsufficientCollateral();
    error BorrowTooSmall();
    error NotLiquidatable();
    error SupplyCapExceeded();
    error InvalidLiquidationFactor();
    error InvalidBorrowCollateralFactor();
    error InvalidLiquidateCollateralFactor();
    error InsufficientReserves();
    error NotForSale();
    
    function supply(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function supplyCollateral(address asset, uint256 amount) external;
    function withdrawCollateral(address asset, uint256 amount) external;
    function absorb(address borrower) external;
    function absorbMultiple(address absorber, address[] calldata accounts) external;
    function buyCollateral(address asset, uint256 minAmount, uint256 baseAmount, address recipient) external;
    function getBalance(address account) external view returns (int256);
    function getCollateral(address account, address asset) external view returns (uint256);
    function isLiquidatable(address account) external view returns (bool);
    function getSupplyRate() external view returns (uint64);
    function getBorrowRate() external view returns (uint64);
    function supplyBalanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function quoteCollateral(address asset, uint256 baseAmount) external view returns (uint256);
    function getReserves() external view returns (int256);
    function getCollateralReserves(address asset) external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function withdrawReserves(address to, uint256 amount) external;
    function setBaseBorrowMin(uint104 newBaseBorrowMin) external;
}