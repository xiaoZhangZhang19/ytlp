// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IYTPoolManager {
    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdy,
        uint256 _minYtLP
    ) external returns (uint256);
    
    function removeLiquidityForAccount(
        address _account,
        address _tokenOut,
        uint256 _ytLPAmount,
        uint256 _minOut,
        address _receiver
    ) external returns (uint256);
    
    function getPrice(bool _maximise) external view returns (uint256);
    function getAumInUsdy(bool _maximise) external view returns (uint256);
    function getAddLiquidityOutput(address _token, uint256 _amount) external view returns (uint256 usdyAmount, uint256 ytLPMintAmount);
    function getRemoveLiquidityOutput(address _tokenOut, uint256 _ytLPAmount) external view returns (uint256 usdyAmount, uint256 amountOut);
    function onLPTransfer(address _from, address _to) external;
}