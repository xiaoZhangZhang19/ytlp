// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IYTVault {
    function buyUSDY(address _token, address _receiver) external returns (uint256);
    function sellUSDY(address _token, address _receiver) external returns (uint256);
    function swap(address _tokenIn, address _tokenOut, address _receiver) external returns (uint256);
    function getPoolValue(bool _maximise) external view returns (uint256);
    function getPrice(address _token, bool _maximise) external view returns (uint256);
    function getMaxPrice(address _token) external view returns (uint256);
    function getMinPrice(address _token) external view returns (uint256);
    function getSwapFeeBasisPoints(address _tokenIn, address _tokenOut, uint256 _usdyAmount) external view returns (uint256);
    function getRedemptionFeeBasisPoints(address _token, uint256 _usdyAmount) external view returns (uint256);
    function getSwapAmountOut(address _tokenIn, address _tokenOut, uint256 _amountIn) external view returns (uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints); 
    function ytPrice() external view returns (uint256);
    function wusdPrice() external view returns (uint256);
}

