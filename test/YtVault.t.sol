// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/ytVault/YTAssetVault.sol";
import "../contracts/ytVault/YTAssetFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Mock USDC token for testing (18 decimals like on BSC)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 100000000 * 1e18); // 铸造1亿USDC用于测试
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock Chainlink Price Feed
contract MockChainlinkPriceFeed is AggregatorV3Interface {
    int256 private _price;
    uint8 private _decimals;
    
    constructor(int256 initialPrice) {
        _price = initialPrice;
        _decimals = 8; // Chainlink standard
    }
    
    function decimals() external view override returns (uint8) {
        return _decimals;
    }
    
    function description() external pure override returns (string memory) {
        return "Mock USDC/USD Price Feed";
    }
    
    function version() external pure override returns (uint256) {
        return 1;
    }
    
    function getRoundData(uint80)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, _price, block.timestamp, block.timestamp, 0);
    }
    
    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, _price, block.timestamp, block.timestamp, 0);
    }
    
    // Helper function to update price in tests
    function updatePrice(int256 newPrice) external {
        _price = newPrice;
    }
}

contract VaultTest is Test {
    YTAssetFactory public factory;
    YTAssetVault public vaultImplementation;
    YTAssetVault public vault;
    MockUSDC public usdc;
    MockChainlinkPriceFeed public usdcPriceFeed;
    
    address public owner;
    address public manager;
    address public user1;
    address public user2;
    
    // 常量
    uint256 constant PRICE_PRECISION = 1e30;
    uint256 constant CHAINLINK_PRECISION = 1e8;
    uint256 constant INITIAL_USDC_PRICE = 1e8; // $1.00 in Chainlink format (1e8)
    uint256 constant INITIAL_YT_PRICE = 1e30;   // 1.0 in PRICE_PRECISION
    uint256 constant HARD_CAP = 1000000 * 1e18; // 100万YT
    
    event VaultCreated(
        address indexed vault,
        address indexed manager,
        string name,
        string symbol,
        uint256 hardCap,
        uint256 index
    );
    event Buy(address indexed user, uint256 usdcAmount, uint256 ytAmount);
    event Sell(address indexed user, uint256 ytAmount, uint256 usdcAmount);
    event PriceUpdated(uint256 ytPrice, uint256 timestamp);
    event AssetsWithdrawn(address indexed to, uint256 amount);
    event AssetsDeposited(uint256 amount);
    event HardCapSet(uint256 newHardCap);
    event NextRedemptionTimeSet(uint256 newRedemptionTime);
    event WithdrawRequestCreated(uint256 indexed requestId, address indexed user, uint256 ytAmount, uint256 usdcAmount, uint256 queueIndex);
    event WithdrawRequestProcessed(uint256 indexed requestId, address indexed user, uint256 usdcAmount);
    event BatchProcessed(uint256 startIndex, uint256 endIndex, uint256 processedCount, uint256 totalUsdcDistributed);

    function setUp() public {
        // 设置测试账户
        owner = address(this);
        manager = makeAddr("manager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // 部署Mock USDC (18 decimals)
        usdc = new MockUSDC();
        
        // 部署Mock Chainlink Price Feed
        usdcPriceFeed = new MockChainlinkPriceFeed(int256(INITIAL_USDC_PRICE));
        
        // 部署实现合约
        vaultImplementation = new YTAssetVault();
        
        // 部署并初始化Factory
        YTAssetFactory factoryImpl = new YTAssetFactory();
        bytes memory factoryInitData = abi.encodeWithSelector(
            YTAssetFactory.initialize.selector,
            address(vaultImplementation),
            HARD_CAP // 默认硬顶
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        factory = YTAssetFactory(address(factoryProxy));
        
        // 给测试用户分配USDC
        usdc.transfer(user1, 100000 * 1e18); // 10万USDC
        usdc.transfer(user2, 100000 * 1e18); // 10万USDC
        usdc.transfer(manager, 100000 * 1e18); // 10万USDC给manager
    }
    
    function _createVault() internal returns (YTAssetVault) {
        uint256 redemptionTime = block.timestamp + 30 days;
        
        address vaultAddr = factory.createVault(
            "YT-A Token",
            "YT-A",
            manager,
            HARD_CAP,
            address(usdc),
            redemptionTime,
            INITIAL_YT_PRICE,
            address(usdcPriceFeed)
        );
        
        return YTAssetVault(vaultAddr);
    }
    
    function test_01_FactoryInitialization() public view {
        assertEq(factory.vaultImplementation(), address(vaultImplementation));
        assertEq(factory.defaultHardCap(), HARD_CAP);
        assertEq(factory.owner(), owner);
    }
    
    function test_02_CreateVault() public {
        uint256 redemptionTime = block.timestamp + 30 days;
        
        vm.expectEmit(false, true, false, true);
        emit VaultCreated(
            address(0), // vault地址未知，所以用0
            manager,
            "YT-A Token",
            "YT-A",
            HARD_CAP,
            0 // 第一个vault，索引为0
        );
        
        address vaultAddr = factory.createVault(
            "YT-A Token",
            "YT-A",
            manager,
            HARD_CAP,
            address(usdc),
            redemptionTime,
            INITIAL_YT_PRICE,
            address(usdcPriceFeed)
        );
        
        vault = YTAssetVault(vaultAddr);
        
        // 验证vault基本信息
        assertEq(vault.name(), "YT-A Token");
        assertEq(vault.symbol(), "YT-A");
        assertEq(vault.manager(), manager);
        assertEq(vault.hardCap(), HARD_CAP);
        assertEq(vault.usdcAddress(), address(usdc));
        assertEq(vault.ytPrice(), INITIAL_YT_PRICE);
        assertEq(vault.nextRedemptionTime(), redemptionTime);
        assertEq(vault.factory(), address(factory));
        assertEq(vault.usdcDecimals(), 18); // BSC USDC uses 18 decimals
        
        // 验证factory记录
        assertEq(factory.getVaultCount(), 1);
        assertTrue(factory.isVault(vaultAddr));
    }
    
    function test_03_CreateVaultWithCustomPrice() public {
        uint256 customYtPrice = 1020000000000000000000000000000;   // 1.02
        uint256 redemptionTime = block.timestamp + 60 days;
        
        address vaultAddr = factory.createVault(
            "YT-B Token",
            "YT-B",
            manager,
            HARD_CAP,
            address(usdc),
            redemptionTime,
            customYtPrice,
            address(usdcPriceFeed)
        );
        
        YTAssetVault customVault = YTAssetVault(vaultAddr);
        
        assertEq(customVault.ytPrice(), customYtPrice);
    }
    
    function test_04_CreateVaultWithZeroPrice() public {
        // 传入0价格应该使用默认值
        uint256 redemptionTime = block.timestamp + 30 days;
        
        address vaultAddr = factory.createVault(
            "YT-C Token",
            "YT-C",
            manager,
            HARD_CAP,
            address(usdc),
            redemptionTime,
            0,  // 使用默认价格
            address(usdcPriceFeed)
        );
        
        YTAssetVault defaultVault = YTAssetVault(vaultAddr);
        
        assertEq(defaultVault.ytPrice(), PRICE_PRECISION);  // 1.0
    }
    
    function test_05_CannotCreateVaultWithZeroManager() public {
        vm.expectRevert(YTAssetFactory.InvalidAddress.selector);
        factory.createVault(
            "YT-D Token",
            "YT-D",
            address(0), // 无效的manager地址
            HARD_CAP,
            address(usdc),
            block.timestamp + 30 days,
            INITIAL_YT_PRICE,
            address(usdcPriceFeed)
        );
    }
    
    function test_06_CannotCreateVaultWithInvalidPriceFeed() public {
        vm.expectRevert(YTAssetVault.InvalidPriceFeed.selector);
        factory.createVault(
            "YT-E Token",
            "YT-E",
            manager,
            HARD_CAP,
            address(usdc),
            block.timestamp + 30 days,
            INITIAL_YT_PRICE,
            address(0) // 无效的价格feed
        );
    }
    
    function test_07_CreateVaultOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.createVault(
            "YT-E Token",
            "YT-E",
            manager,
            HARD_CAP,
            address(usdc),
            block.timestamp + 30 days,
            INITIAL_YT_PRICE,
            address(usdcPriceFeed)
        );
    }
    
    function test_08_DepositYT() public {
        vault = _createVault();
        
        uint256 depositAmount = 1000 * 1e18; // 1000 USDC
        uint256 expectedYtAmount = 1000 * 1e18; // 价格1:1，获得1000 YT
        
        // 授权
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        
        // 预览购买
        uint256 previewAmount = vault.previewBuy(depositAmount);
        assertEq(previewAmount, expectedYtAmount);
        
        // 存款
        vm.expectEmit(true, false, false, true);
        emit Buy(user1, depositAmount, expectedYtAmount);
        
        uint256 ytReceived = vault.depositYT(depositAmount);
        vm.stopPrank();
        
        // 验证结果
        assertEq(ytReceived, expectedYtAmount);
        assertEq(vault.balanceOf(user1), expectedYtAmount);
        assertEq(vault.totalSupply(), expectedYtAmount);
        assertEq(usdc.balanceOf(address(vault)), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.idleAssets(), depositAmount);
    }
    
    function test_09_DepositYTWithDifferentPrices() public {
        vault = _createVault();
        
        // 更新YT价格为 1.02，USDC保持 $1.00
        factory.updateVaultPrices(
            address(vault),
            1020000000000000000000000000000  // 1.02
        );
        
        uint256 depositAmount = 1000 * 1e18; // 1000 USDC
        // ytAmount = 1000 USDC * $1.00 / $1.02 = 980.392156862745098039 YT
        // 使用公式: ytAmount = depositAmount * usdcPrice * conversionFactor / ytPrice
        // conversionFactor = 10^18 * 10^30 / (10^18 * 10^8) = 10^22
        uint256 expectedYtAmount = (depositAmount * INITIAL_USDC_PRICE * 1e22) / 1020000000000000000000000000000;
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 ytReceived = vault.depositYT(depositAmount);
        vm.stopPrank();
        
        // 精确验证计算结果
        assertEq(ytReceived, expectedYtAmount);
        assertEq(ytReceived, 980392156862745098039); // 约980.39 YT
    }
    
    function test_10_DepositYTMultipleUsers() public {
        vault = _createVault();
        
        uint256 amount1 = 1000 * 1e18;
        uint256 amount2 = 2000 * 1e18;
        
        // User1存款
        vm.startPrank(user1);
        usdc.approve(address(vault), amount1);
        vault.depositYT(amount1);
        vm.stopPrank();
        
        // User2存款
        vm.startPrank(user2);
        usdc.approve(address(vault), amount2);
        vault.depositYT(amount2);
        vm.stopPrank();
        
        // 验证余额
        assertEq(vault.balanceOf(user1), amount1);
        assertEq(vault.balanceOf(user2), amount2);
        assertEq(vault.totalSupply(), amount1 + amount2);
        assertEq(vault.totalAssets(), amount1 + amount2);
    }
    
    function test_11_CannotDepositZeroAmount() public {
        vault = _createVault();
        
        vm.startPrank(user1);
        vm.expectRevert(YTAssetVault.InvalidAmount.selector);
        vault.depositYT(0);
        vm.stopPrank();
    }
    
    function test_12_DepositYTHardCapEnforcement() public {
        vault = _createVault();
        
        // 尝试存款超过硬顶
        uint256 overCapAmount = HARD_CAP + 1000 * 1e18;
        
        vm.startPrank(user1);
        usdc.mint(user1, overCapAmount); // 铸造足够的USDC
        usdc.approve(address(vault), overCapAmount);
        
        vm.expectRevert(YTAssetVault.HardCapExceeded.selector);
        vault.depositYT(overCapAmount);
        vm.stopPrank();
    }
    
    function test_13_DepositYTExactlyAtHardCap() public {
        vault = _createVault();
        
        vm.startPrank(user1);
        usdc.mint(user1, HARD_CAP);
        usdc.approve(address(vault), HARD_CAP);
        vault.depositYT(HARD_CAP);
        vm.stopPrank();
        
        assertEq(vault.totalSupply(), HARD_CAP);
        assertEq(vault.balanceOf(user1), HARD_CAP);
    }
    
    function test_14_WithdrawYT() public {
        vault = _createVault();
        
        // 先存款
        uint256 depositAmount = 1000 * 1e18;
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.depositYT(depositAmount);
        vm.stopPrank();
        
        // 快进到赎回时间之后
        vm.warp(vault.nextRedemptionTime() + 1);
        
        // 提交提现请求
        uint256 withdrawAmount = 500 * 1e18; // 提取500 YT
        uint256 expectedUsdc = 500 * 1e18;   // 价格1:1，获得500 USDC
        
        uint256 user1UsdcBefore = usdc.balanceOf(user1);
        
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit WithdrawRequestCreated(0, user1, withdrawAmount, expectedUsdc, 0);
        
        uint256 requestId = vault.withdrawYT(withdrawAmount);
        vm.stopPrank();
        
        // 验证请求创建
        assertEq(requestId, 0);
        assertEq(vault.balanceOf(user1), depositAmount - withdrawAmount); // YT已销毁
        assertEq(vault.totalSupply(), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(user1), user1UsdcBefore); // USDC还未发放
        assertEq(vault.pendingRequestsCount(), 1);
        
        // 批量处理提现请求
        vm.prank(manager);
        (uint256 processedCount, uint256 totalDistributed) = vault.processBatchWithdrawals(10);
        
        // 验证结果
        assertEq(processedCount, 1);
        assertEq(totalDistributed, expectedUsdc);
        assertEq(usdc.balanceOf(user1), user1UsdcBefore + expectedUsdc); // 现在收到了USDC
        assertEq(vault.pendingRequestsCount(), 0);
    }
    
    function test_15_WithdrawYTWithDifferentPrices() public {
        vault = _createVault();
        
        // 存款
        uint256 depositAmount = 1000 * 1e18;
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        vault.depositYT(depositAmount);
        vm.stopPrank();
        
        // 更新YT价格为 1.05 (YT升值)，USDC价格更新为 0.98
        factory.updateVaultPrices(
            address(vault),
            1050000000000000000000000000000  // 1.05
        );
        usdcPriceFeed.updatePrice(98000000); // $0.98 in Chainlink format
        
        // 快进到赎回时间
        vm.warp(vault.nextRedemptionTime() + 1);
        
        // 提交提现请求
        uint256 withdrawAmount = 500 * 1e18;
        // usdcAmount = 500 YT * $1.05 / $0.98 = 535.714285714285714285 USDC
        // 使用公式: usdcAmount = ytAmount * ytPrice / (usdcPrice * conversionFactor)
        uint256 expectedUsdc = (withdrawAmount * 1050000000000000000000000000000) / (98000000 * 1e22);
        
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        
        vm.startPrank(user1);
        uint256 requestId = vault.withdrawYT(withdrawAmount);
        vm.stopPrank();
        
        assertEq(requestId, 0);
        
        // 批量处理
        vm.prank(manager);
        vault.processBatchWithdrawals(10);
        
        // 验证用户收到的USDC（余额增加量）
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + expectedUsdc);
        assertEq(expectedUsdc, 535714285714285714285); // 约535.71 USDC
    }
    
    function test_16_CannotWithdrawBeforeRedemptionTime() public {
        vault = _createVault();
        
        // 存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        vault.depositYT(1000 * 1e18);
        
        // 尝试在赎回时间前提款
        vm.expectRevert(YTAssetVault.StillInLockPeriod.selector);
        vault.withdrawYT(500 * 1e18);
        vm.stopPrank();
    }
    
    function test_17_CannotWithdrawZeroAmount() public {
        vault = _createVault();
        
        vm.warp(vault.nextRedemptionTime() + 1);
        
        vm.startPrank(user1);
        vm.expectRevert(YTAssetVault.InvalidAmount.selector);
        vault.withdrawYT(0);
        vm.stopPrank();
    }
    
    function test_18_CannotWithdrawMoreThanBalance() public {
        vault = _createVault();
        
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        vault.depositYT(1000 * 1e18);
        vm.stopPrank();
        
        vm.warp(vault.nextRedemptionTime() + 1);
        
        vm.startPrank(user1);
        vm.expectRevert(YTAssetVault.InsufficientYTA.selector);
        vault.withdrawYT(2000 * 1e18);
        vm.stopPrank();
    }
    
    function test_19_ProcessStopsWhenInsufficientUSDC() public {
        vault = _createVault();
        
        // User1存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        vault.depositYT(1000 * 1e18);
        vm.stopPrank();
        
        // Manager提取所有USDC
        vm.prank(manager);
        vault.withdrawForManagement(manager, 1000 * 1e18);
        
        // 快进到赎回时间
        vm.warp(vault.nextRedemptionTime() + 1);
        
        // User1可以提交提现请求（即使vault中没有USDC）
        vm.startPrank(user1);
        uint256 requestId = vault.withdrawYT(500 * 1e18);
        vm.stopPrank();
        
        assertEq(requestId, 0);
        assertEq(vault.pendingRequestsCount(), 1);
        
        // 但是批量处理时会因为资金不足而处理0个请求
        vm.prank(manager);
        (uint256 processedCount, ) = vault.processBatchWithdrawals(10);
        
        assertEq(processedCount, 0); // 没有处理任何请求
        assertEq(vault.pendingRequestsCount(), 1); // 请求仍在队列中
        
        // Manager归还资金后可以处理
        vm.startPrank(manager);
        usdc.approve(address(vault), 1000 * 1e18);
        vault.depositManagedAssets(1000 * 1e18);
        vm.stopPrank();
        
        // 现在可以处理了
        vm.prank(manager);
        (uint256 processedCount2, ) = vault.processBatchWithdrawals(10);
        
        assertEq(processedCount2, 1);
        assertEq(vault.pendingRequestsCount(), 0);
    }
    
    function test_20_UpdatePrices() public {
        vault = _createVault();
        
        uint256 newYtPrice = 1020000000000000000000000000000;   // 1.02
        
        vm.expectEmit(false, false, false, true);
        emit PriceUpdated(newYtPrice, block.timestamp);
        
        factory.updateVaultPrices(address(vault), newYtPrice);
        
        assertEq(vault.ytPrice(), newYtPrice);
    }
    
    function test_21_UpdatePricesOnlyFactory() public {
        vault = _createVault();
        
        // 测试非factory调用者（包括manager）无法直接调用
        vm.prank(user1);
        vm.expectRevert(YTAssetVault.Forbidden.selector);
        vault.updatePrices(1020000000000000000000000000000);
        
        // manager也不能直接调用
        vm.prank(manager);
        vm.expectRevert(YTAssetVault.Forbidden.selector);
        vault.updatePrices(1020000000000000000000000000000);
    }
    
    function test_22_CannotUpdatePricesWithZero() public {
        vault = _createVault();
        
        vm.expectRevert(YTAssetVault.InvalidPrice.selector);
        factory.updateVaultPrices(address(vault), 0);
    }
    
    function test_23_WithdrawForManagement() public {
        vault = _createVault();
        
        // 先存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositYT(10000 * 1e18);
        vm.stopPrank();
        
        // Manager提取用于投资
        uint256 withdrawAmount = 5000 * 1e18;
        uint256 managerBalanceBefore = usdc.balanceOf(manager);
        
        vm.expectEmit(true, false, false, true);
        emit AssetsWithdrawn(manager, withdrawAmount);
        
        vm.prank(manager);
        vault.withdrawForManagement(manager, withdrawAmount);
        
        // 验证
        assertEq(vault.managedAssets(), withdrawAmount);
        assertEq(vault.idleAssets(), 5000 * 1e18);
        assertEq(vault.totalAssets(), 10000 * 1e18); // totalAssets = idle + managed
        assertEq(usdc.balanceOf(manager), managerBalanceBefore + withdrawAmount);
    }
    
    function test_24_DepositManagedAssetsFullReturn() public {
        vault = _createVault();
        
        // 存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositYT(10000 * 1e18);
        vm.stopPrank();
        
        // Manager提取
        vm.prank(manager);
        vault.withdrawForManagement(manager, 5000 * 1e18);
        
        // Manager归还全部（无盈亏）
        vm.startPrank(manager);
        usdc.approve(address(vault), 5000 * 1e18);
        
        vm.expectEmit(false, false, false, true);
        emit AssetsDeposited(5000 * 1e18);
        
        vault.depositManagedAssets(5000 * 1e18);
        vm.stopPrank();
        
        // 验证
        assertEq(vault.managedAssets(), 0);
        assertEq(vault.idleAssets(), 10000 * 1e18);
        assertEq(vault.totalAssets(), 10000 * 1e18);
    }
    
    function test_25_DepositManagedAssetsWithProfit() public {
        vault = _createVault();
        
        // 存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositYT(10000 * 1e18);
        vm.stopPrank();
        
        // Manager提取
        vm.prank(manager);
        vault.withdrawForManagement(manager, 5000 * 1e18);
        
        // Manager归还本金+利润
        uint256 returnAmount = 6000 * 1e18; // 赚了1000 USDC
        vm.startPrank(manager);
        usdc.approve(address(vault), returnAmount);
        vault.depositManagedAssets(returnAmount);
        vm.stopPrank();
        
        // 验证
        assertEq(vault.managedAssets(), 0);
        assertEq(vault.idleAssets(), 11000 * 1e18); // 5000 + 6000
        assertEq(vault.totalAssets(), 11000 * 1e18); // 增加了1000的利润
    }
    
    function test_26_SetHardCap() public {
        vault = _createVault();
        
        uint256 newHardCap = 2000000 * 1e18;
        
        vm.expectEmit(false, false, false, true);
        emit HardCapSet(newHardCap);
        
        factory.setHardCap(address(vault), newHardCap);
        
        assertEq(vault.hardCap(), newHardCap);
    }
    
    function test_27_CannotSetHardCapBelowTotalSupply() public {
        vault = _createVault();
        
        // 先存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 100000 * 1e18);
        vault.depositYT(100000 * 1e18);
        vm.stopPrank();
        
        // 尝试设置低于当前总供应量的硬顶
        vm.expectRevert(YTAssetVault.InvalidHardCap.selector);
        factory.setHardCap(address(vault), 50000 * 1e18);
    }
    
    function test_28_SetNextRedemptionTime() public {
        vault = _createVault();
        
        uint256 newRedemptionTime = block.timestamp + 90 days;
        
        vm.expectEmit(false, false, false, true);
        emit NextRedemptionTimeSet(newRedemptionTime);
        
        factory.setVaultNextRedemptionTime(address(vault), newRedemptionTime);
        
        assertEq(vault.nextRedemptionTime(), newRedemptionTime);
    }
    
    function test_29_PauseByFactory() public {
        vault = _createVault();
        
        // Factory可以暂停
        factory.pauseVault(address(vault));
        assertTrue(vault.paused());
        
        // Factory可以恢复
        factory.unpauseVault(address(vault));
        assertFalse(vault.paused());
    }
    
    function test_30_OnlyFactoryCanPause() public {
        vault = _createVault();
        
        // User不能暂停
        vm.startPrank(user1);
        vm.expectRevert(YTAssetVault.Forbidden.selector);
        vault.pause();
        vm.stopPrank();
        
        // Manager也不能暂停
        vm.startPrank(manager);
        vm.expectRevert(YTAssetVault.Forbidden.selector);
        vault.pause();
        vm.stopPrank();
    }
    
    function test_31_CannotDepositWhenPaused() public {
        vault = _createVault();
        
        // 暂停vault
        factory.pauseVault(address(vault));
        
        // 尝试存款应该失败
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.depositYT(1000 * 1e18);
        vm.stopPrank();
        
        // 恢复后应该可以存款
        factory.unpauseVault(address(vault));
        
        vm.startPrank(user1);
        uint256 ytReceived = vault.depositYT(1000 * 1e18);
        vm.stopPrank();
        
        assertEq(ytReceived, 1000 * 1e18);
    }
    
    function test_32_GetVaultInfo() public {
        vault = _createVault();
        
        // 存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositYT(10000 * 1e18);
        vm.stopPrank();
        
        // Manager提取部分资金
        vm.prank(manager);
        vault.withdrawForManagement(manager, 3000 * 1e18);
        
        (
            uint256 totalAssets,
            uint256 idleAssets,
            uint256 managedAssets_,
            uint256 totalSupply_,
            uint256 hardCap_,
            uint256 usdcPrice,
            uint256 ytPrice_,
            uint256 nextRedemptionTime_
        ) = vault.getVaultInfo();
        
        assertEq(totalAssets, 10000 * 1e18);
        assertEq(idleAssets, 7000 * 1e18);
        assertEq(managedAssets_, 3000 * 1e18);
        assertEq(totalSupply_, 10000 * 1e18);
        assertEq(hardCap_, HARD_CAP);
        assertEq(usdcPrice, INITIAL_USDC_PRICE);
        assertEq(ytPrice_, INITIAL_YT_PRICE);
        assertEq(nextRedemptionTime_, vault.nextRedemptionTime());
    }
    
    function test_33_PreviewFunctions() public {
        vault = _createVault();
        
        // 更新价格
        factory.updateVaultPrices(
            address(vault),
            1020000000000000000000000000000  // YT = 1.02
        );
        
        // 预览买入
        uint256 usdcAmount = 1000 * 1e18;
        uint256 expectedYt = (usdcAmount * INITIAL_USDC_PRICE * 1e22) / 1020000000000000000000000000000;
        uint256 previewBuyAmount = vault.previewBuy(usdcAmount);
        assertEq(previewBuyAmount, expectedYt);
        assertEq(previewBuyAmount, 980392156862745098039);
        
        // 预览卖出
        uint256 ytAmount = 1000 * 1e18;
        uint256 expectedUsdc = (ytAmount * 1020000000000000000000000000000) / (INITIAL_USDC_PRICE * 1e22);
        uint256 previewSellAmount = vault.previewSell(ytAmount);
        assertEq(previewSellAmount, expectedUsdc);
        assertEq(previewSellAmount, 1020000000000000000000);
    }
    
    function test_34_CanRedeemNow() public {
        vault = _createVault();
        
        // 赎回时间前
        assertFalse(vault.canRedeemNow());
        
        // 赎回时间后
        vm.warp(vault.nextRedemptionTime() + 1);
        assertTrue(vault.canRedeemNow());
    }
    
    function test_35_GetTimeUntilNextRedemption() public {
        vault = _createVault();
        
        uint256 redemptionTime = vault.nextRedemptionTime();
        uint256 currentTime = block.timestamp;
        
        assertEq(vault.getTimeUntilNextRedemption(), redemptionTime - currentTime);
        
        // 快进到赎回时间后
        vm.warp(redemptionTime + 1);
        assertEq(vault.getTimeUntilNextRedemption(), 0);
    }
    
    function test_36_CompleteLifecycle() public {
        vault = _createVault();
        
        // 1. 初始状态验证
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        
        // 2. User1和User2存款
        vm.startPrank(user1);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositYT(10000 * 1e18);
        vm.stopPrank();
        
        vm.startPrank(user2);
        usdc.approve(address(vault), 5000 * 1e18);
        vault.depositYT(5000 * 1e18);
        vm.stopPrank();
        
        assertEq(vault.totalSupply(), 15000 * 1e18);
        assertEq(vault.totalAssets(), 15000 * 1e18);
        
        // 3. Manager提取资金进行投资
        vm.prank(manager);
        vault.withdrawForManagement(manager, 8000 * 1e18);
        
        assertEq(vault.managedAssets(), 8000 * 1e18);
        assertEq(vault.idleAssets(), 7000 * 1e18);
        assertEq(vault.totalAssets(), 15000 * 1e18);
        
        // 4. 价格更新（YT涨到1.10）
        factory.updateVaultPrices(
            address(vault),
            1100000000000000000000000000000  // YT涨到1.10
        );
        
        // 5. Manager归还资金+利润
        vm.startPrank(manager);
        usdc.approve(address(vault), 10000 * 1e18);
        vault.depositManagedAssets(10000 * 1e18); // 归还本金+2000利润
        vm.stopPrank();
        
        assertEq(vault.managedAssets(), 0);
        assertEq(vault.idleAssets(), 17000 * 1e18); // 增加了2000利润
        assertEq(vault.totalAssets(), 17000 * 1e18);
        
        // 6. 快进到赎回时间
        vm.warp(vault.nextRedemptionTime() + 1);
        
        // 7. User1提交提现请求
        uint256 user1YtBalance = vault.balanceOf(user1);
        uint256 withdrawYtAmount = 5000 * 1e18;
        uint256 user1UsdcBefore = usdc.balanceOf(user1);
        
        vm.startPrank(user1);
        uint256 requestId = vault.withdrawYT(withdrawYtAmount);
        vm.stopPrank();
        
        assertEq(requestId, 0);
        
        // 8. 批量处理提现
        vm.prank(manager);
        vault.processBatchWithdrawals(10);
        
        // 按新价格计算: 5000 YT * $1.10 / $1.00 = 5500 USDC
        uint256 expectedUsdc = (withdrawYtAmount * 1100000000000000000000000000000) / (INITIAL_USDC_PRICE * 1e22);
        assertEq(usdc.balanceOf(user1), user1UsdcBefore + expectedUsdc);
        assertEq(expectedUsdc, 5500000000000000000000);
        
        // 验证最终状态
        assertEq(vault.balanceOf(user1), user1YtBalance - withdrawYtAmount);
        assertEq(vault.totalSupply(), 10000 * 1e18);
    }
    
    function test_37_ChainlinkPriceIntegration() public {
        vault = _createVault();
        
        // 测试不同的USDC价格
        usdcPriceFeed.updatePrice(105000000); // $1.05
        
        uint256 depositAmount = 1000 * 1e18;
        // ytAmount = 1000 * 1.05 / 1.00 = 1050 YT
        uint256 expectedYt = (depositAmount * 105000000 * 1e22) / INITIAL_YT_PRICE;
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 ytReceived = vault.depositYT(depositAmount);
        vm.stopPrank();
        
        assertEq(ytReceived, expectedYt);
        assertEq(ytReceived, 1050 * 1e18);
    }
    
    function test_38_ChainlinkNegativePriceReverts() public {
        vault = _createVault();
        
        // 设置负价格
        usdcPriceFeed.updatePrice(-1);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        
        // 应该revert
        vm.expectRevert(YTAssetVault.InvalidChainlinkPrice.selector);
        vault.depositYT(1000 * 1e18);
        vm.stopPrank();
    }
    
    function test_39_ChainlinkZeroPriceReverts() public {
        vault = _createVault();
        
        // 设置零价格
        usdcPriceFeed.updatePrice(0);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000 * 1e18);
        
        // 应该revert
        vm.expectRevert(YTAssetVault.InvalidChainlinkPrice.selector);
        vault.depositYT(1000 * 1e18);
        vm.stopPrank();
    }
    
    function test_40_BatchProcessWithMultipleRequests() public {
        vault = _createVault();
        
        // 准备5个用户和请求
        address[] memory users = new address[](5);
        for (uint i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            usdc.transfer(users[i], 1000 * 1e18);
            
            vm.startPrank(users[i]);
            usdc.approve(address(vault), 1000 * 1e18);
            vault.depositYT(1000 * 1e18);
            vm.stopPrank();
        }
        
        // 快进到赎回时间
        vm.warp(vault.nextRedemptionTime() + 1);
        
        // 提交5个提现请求
        for (uint i = 0; i < 5; i++) {
            vm.prank(users[i]);
            vault.withdrawYT(500 * 1e18);
        }
        
        assertEq(vault.pendingRequestsCount(), 5);
        
        // 第一次批量处理：只处理2个
        vm.prank(manager);
        (uint256 processedCount1, ) = vault.processBatchWithdrawals(2);
        
        assertEq(processedCount1, 2);
        assertEq(vault.pendingRequestsCount(), 3);
        
        // 第二次批量处理：处理剩余3个
        vm.prank(manager);
        (uint256 processedCount2, ) = vault.processBatchWithdrawals(10);
        
        assertEq(processedCount2, 3);
        assertEq(vault.pendingRequestsCount(), 0);
    }
}
