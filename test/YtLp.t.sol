// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/ytLp/tokens/USDY.sol";
import "../contracts/ytLp/tokens/YTLPToken.sol";
import "../contracts/ytLp/core/YTPriceFeed.sol";
import "../contracts/ytLp/core/YTVault.sol";
import "../contracts/ytLp/core/YTPoolManager.sol";
import "../contracts/ytLp/core/YTRewardRouter.sol";
import "../contracts/ytVault/YTAssetVault.sol";
import "../contracts/ytVault/YTAssetFactory.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Mock USDC token for testing (18 decimals like on BSC)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 100000000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public pure override returns (uint8) {
        return 18; // BSC USDC uses 18 decimals
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

contract YTLpTest is Test {
    address deployer;
    address user1;
    address user2;
    address user3;
    
    USDY usdy;
    YTLPToken ytlp;
    YTPriceFeed priceFeed;
    YTVault vault;
    YTPoolManager poolManager;
    YTRewardRouter router;
    MockUSDC usdc;
    MockChainlinkPriceFeed usdcPriceFeed;
    YTAssetFactory factory;
    
    YTAssetVault ytTokenA;
    YTAssetVault ytTokenB;
    YTAssetVault ytTokenC;
    
    uint256 constant PRICE_PRECISION = 1e30;
    uint256 constant CHAINLINK_PRECISION = 1e8;
    uint256 constant INITIAL_USDC_PRICE = 1e8; // $1.00 in Chainlink format
    uint256 constant BASIS_POINTS = 10000;
    
    function setUp() public {
        deployer = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);
        
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        
        // 部署 Mock USDC (18 decimals)
        usdc = new MockUSDC();
        
        // 部署 Mock Chainlink Price Feed
        usdcPriceFeed = new MockChainlinkPriceFeed(int256(INITIAL_USDC_PRICE));
        
        // 使用代理模式部署 USDY
        USDY usdyImpl = new USDY();
        bytes memory usdyInitData = abi.encodeWithSelector(USDY.initialize.selector);
        ERC1967Proxy usdyProxy = new ERC1967Proxy(address(usdyImpl), usdyInitData);
        usdy = USDY(address(usdyProxy));
        
        // 使用代理模式部署 YTLPToken
        YTLPToken ytlpImpl = new YTLPToken();
        bytes memory ytlpInitData = abi.encodeWithSelector(YTLPToken.initialize.selector);
        ERC1967Proxy ytlpProxy = new ERC1967Proxy(address(ytlpImpl), ytlpInitData);
        ytlp = YTLPToken(address(ytlpProxy));
        
        // 使用代理模式部署 YTPriceFeed
        YTPriceFeed priceFeedImpl = new YTPriceFeed();
        bytes memory priceFeedInitData = abi.encodeWithSelector(
            YTPriceFeed.initialize.selector,
            address(usdc),
            address(usdcPriceFeed)
        );
        ERC1967Proxy priceFeedProxy = new ERC1967Proxy(address(priceFeedImpl), priceFeedInitData);
        priceFeed = YTPriceFeed(address(priceFeedProxy));
        
        // 使用代理模式部署 YTVault
        YTVault vaultImpl = new YTVault();
        bytes memory vaultInitData = abi.encodeWithSelector(
            YTVault.initialize.selector,
            address(usdy),
            address(priceFeed)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = YTVault(address(vaultProxy));
        
        // 使用代理模式部署 YTPoolManager
        YTPoolManager poolManagerImpl = new YTPoolManager();
        bytes memory poolManagerInitData = abi.encodeWithSelector(
            YTPoolManager.initialize.selector,
            address(vault),
            address(usdy),
            address(ytlp),
            15 * 60
        );
        ERC1967Proxy poolManagerProxy = new ERC1967Proxy(address(poolManagerImpl), poolManagerInitData);
        poolManager = YTPoolManager(address(poolManagerProxy));
        
        // 使用代理模式部署 YTRewardRouter
        YTRewardRouter routerImpl = new YTRewardRouter();
        bytes memory routerInitData = abi.encodeWithSelector(
            YTRewardRouter.initialize.selector,
            address(usdy),
            address(ytlp),
            address(poolManager),
            address(vault)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInitData);
        router = YTRewardRouter(address(routerProxy));
        
        // 部署YTAssetVault实现合约（不初始化）
        YTAssetVault ytVaultImpl = new YTAssetVault();
        
        // 使用代理模式部署 YTAssetFactory
        YTAssetFactory factoryImpl = new YTAssetFactory();
        bytes memory factoryInitData = abi.encodeWithSelector(
            YTAssetFactory.initialize.selector,
            address(ytVaultImpl),
            1000000 ether // defaultHardCap
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInitData);
        factory = YTAssetFactory(address(factoryProxy));
        
        // 通过factory创建YTAssetVault代币
        address ytTokenAAddr = factory.createVault(
            "YT Token A",
            "YT-A",
            deployer, // manager
            1000000 ether, // hardCap
            address(usdc),
            block.timestamp + 365 days, // redemptionTime
            PRICE_PRECISION, // initialYtPrice
            address(usdcPriceFeed) // usdcPriceFeed
        );
        ytTokenA = YTAssetVault(ytTokenAAddr);
        
        address ytTokenBAddr = factory.createVault(
            "YT Token B",
            "YT-B",
            deployer,
            1000000 ether,
            address(usdc),
            block.timestamp + 365 days,
            PRICE_PRECISION,
            address(usdcPriceFeed)
        );
        ytTokenB = YTAssetVault(ytTokenBAddr);
        
        address ytTokenCAddr = factory.createVault(
            "YT Token C",
            "YT-C",
            deployer,
            1000000 ether,
            address(usdc),
            block.timestamp + 365 days,
            PRICE_PRECISION,
            address(usdcPriceFeed)
        );
        ytTokenC = YTAssetVault(ytTokenCAddr);
        
        // 配置权限
        usdy.addVault(address(vault));
        usdy.addVault(address(poolManager));
        ytlp.setMinter(address(poolManager), true);
        vault.setPoolManager(address(poolManager));
        vault.setSwapper(address(router), true);
        poolManager.setHandler(address(router), true);
        
        // 配置参数
        vault.setSwapFees(30, 4, 50, 20); // 0.3%, 0.04%, 动态税率
        vault.setDynamicFees(false); // 先关闭动态费率，便于精确测试
        vault.setMaxSwapSlippageBps(1000);
        priceFeed.setMaxPriceChangeBps(500);
        
        // 配置白名单
        vault.setWhitelistedToken(address(ytTokenA), 18, 4000, 45000000 ether, false);
        vault.setWhitelistedToken(address(ytTokenB), 18, 3000, 35000000 ether, false);
        vault.setWhitelistedToken(address(ytTokenC), 18, 2000, 25000000 ether, false);
        
        // 初始化价格 $1.00
        priceFeed.forceUpdatePrice(address(ytTokenA), 1e30);
        priceFeed.forceUpdatePrice(address(ytTokenB), 1e30);
        priceFeed.forceUpdatePrice(address(ytTokenC), 1e30);
        
        // 不设置价差（便于精确计算）
        
        // 为测试用户铸造YT代币（需要先给合约USDC，再depositYT）
        uint256 initialAmount = 10000 ether;
        
        // 给deployer一些USDC用于购买YT
        usdc.mint(deployer, 30000 ether);
        
        // Deployer购买YT代币
        usdc.approve(address(ytTokenA), initialAmount);
        ytTokenA.depositYT(initialAmount);
        
        usdc.approve(address(ytTokenB), initialAmount);
        ytTokenB.depositYT(initialAmount);
        
        usdc.approve(address(ytTokenC), initialAmount);
        ytTokenC.depositYT(initialAmount);
        
        // 转账给用户
        ytTokenA.transfer(user1, 5000 ether);
        ytTokenB.transfer(user1, 5000 ether);
        ytTokenC.transfer(user1, 5000 ether);
        
        ytTokenA.transfer(user2, 3000 ether);
        ytTokenB.transfer(user2, 3000 ether);
        
        // 给用户一些USDC（用于后续可能的操作）
        usdc.mint(user1, 10000 ether);
        usdc.mint(user2, 10000 ether);
        usdc.mint(user3, 10000 ether);
    }
    
    // ==================== 1. 部署和初始化测试 ====================
    
    function test_01_DeployContracts() public view {
        assertEq(usdy.name(), "YT USD");
        assertEq(usdy.symbol(), "USDY");
        assertEq(usdy.decimals(), 18);
        
        assertEq(ytlp.name(), "YT Liquidity Provider");
        assertEq(ytlp.symbol(), "ytLP");
        assertEq(ytlp.decimals(), 18);
        
        assertEq(vault.ytPoolManager(), address(poolManager));
        assertEq(poolManager.ytVault(), address(vault));
    }
    
    function test_02_ConfigurePermissions() public view {
        assertTrue(usdy.vaults(address(vault)));
        assertTrue(usdy.vaults(address(poolManager)));
        assertTrue(ytlp.isMinter(address(poolManager)));
        assertTrue(poolManager.isHandler(address(router)));
        assertTrue(vault.isSwapper(address(router)));
    }
    
    function test_03_ConfigureWhitelist() public view {
        assertTrue(vault.whitelistedTokens(address(ytTokenA)));
        assertTrue(vault.whitelistedTokens(address(ytTokenB)));
        assertTrue(vault.whitelistedTokens(address(ytTokenC)));
        
        assertEq(vault.tokenWeights(address(ytTokenA)), 4000);
        assertEq(vault.tokenWeights(address(ytTokenB)), 3000);
        assertEq(vault.tokenWeights(address(ytTokenC)), 2000);
        assertEq(vault.totalTokenWeights(), 9000);
        
        assertFalse(vault.stableTokens(address(ytTokenA)));
        assertTrue(vault.stableTokens(address(usdy))); // USDY被标记为稳定币
    }
    
    function test_04_ConfigureFees() public view {
        assertEq(vault.swapFeeBasisPoints(), 30); // 0.3%
        assertEq(vault.stableSwapFeeBasisPoints(), 4); // 0.04%
        assertEq(vault.taxBasisPoints(), 50);
        assertEq(vault.stableTaxBasisPoints(), 20);
        assertFalse(vault.hasDynamicFees()); // 已关闭便于测试
    }
    
    function test_05_YTAssetVaultBasics() public view {
        assertEq(ytTokenA.name(), "YT Token A");
        assertEq(ytTokenA.symbol(), "YT-A");
        assertEq(ytTokenA.ytPrice(), PRICE_PRECISION);
    }
    
    // ==================== 2. 添加流动性测试（精确计算）====================
    
    function test_06_FirstAddLiquidity() public {
        uint256 depositAmount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), depositAmount);
        
        uint256 ytLPBefore = ytlp.balanceOf(user1);
        assertEq(ytLPBefore, 0);
        
        // 添加流动性
        uint256 ytLPReceived = router.addLiquidity(
            address(ytTokenA),
            depositAmount,
            0,
            0
        );
        
        vm.stopPrank();
        
        // 精确计算预期值（无价差，0.3%手续费）
        // 存入: 1000 YT-A @ $1.00
        // 手续费: 1000 × 0.3% = 3 个代币
        // 扣费后: 997 个代币
        // USDY价值: 997 × $1.00 = 997 USDY
        // 首次铸造: ytLP = USDY = 997 ether
        
        uint256 expectedYtLP = 997 ether;
        assertEq(ytLPReceived, expectedYtLP, "ytLP amount incorrect");
        assertEq(ytlp.balanceOf(user1), expectedYtLP, "user1 balance incorrect");
        assertEq(ytlp.totalSupply(), expectedYtLP, "total supply incorrect");
        
        // 验证池子状态
        assertEq(vault.poolAmounts(address(ytTokenA)), depositAmount, "pool amount incorrect");
        assertEq(vault.usdyAmounts(address(ytTokenA)), expectedYtLP, "usdy amount incorrect");
        
        // 验证ytLP价格
        uint256 ytLPPrice = poolManager.getPrice(true);
        // AUM = 1000 (池子有1000个代币) × $1.00 = $1000
        // Supply = 997 ytLP
        // Price = AUM * 1e18 / Supply (带18位精度)
        assertTrue(ytLPPrice > 1 ether, "ytLP price should be > $1");
    }
    
    function test_07_SecondAddLiquidity() public {
        // 用户1先添加
        uint256 firstAmount = 1000 ether;
        vm.startPrank(user1);
        ytTokenA.approve(address(router), firstAmount);
        router.addLiquidity(address(ytTokenA), firstAmount, 0, 0);
        vm.stopPrank();
        
        uint256 user1YtLP = ytlp.balanceOf(user1); // 997 ether
        
        // 用户2添加
        uint256 secondAmount = 2000 ether;
        vm.startPrank(user2);
        ytTokenB.approve(address(router), secondAmount);
        
        uint256 ytLPReceived = router.addLiquidity(
            address(ytTokenB),
            secondAmount,
            0,
            0
        );
        
        vm.stopPrank();
        
        // 精确计算
        uint256 expectedYtLP = 1988.018 ether;
        assertEq(ytLPReceived, expectedYtLP, "second add ytLP amount incorrect");
        assertEq(ytlp.balanceOf(user2), expectedYtLP, "user2 balance incorrect");
        assertEq(ytlp.totalSupply(), user1YtLP + expectedYtLP, "total supply incorrect");
    }
    
    function test_08_AddLiquiditySlippageProtection() public {
        uint256 amount = 1000 ether;
        uint256 tooHighMinYtLP = 1500 ether; // 设置过高的最小值
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        
        vm.expectRevert(abi.encodeWithSignature("InsufficientOutput()"));
        router.addLiquidity(
            address(ytTokenA),
            amount,
            0,
            tooHighMinYtLP
        );
        vm.stopPrank();
    }
    
    // ==================== 3. 移除流动性测试 ====================
    
    function test_09_RemoveLiquidity() public {
        // 先添加流动性
        uint256 addAmount = 1000 ether;
        vm.startPrank(user1);
        ytTokenA.approve(address(router), addAmount);
        router.addLiquidity(address(ytTokenA), addAmount, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1); // 997 ether
        
        // 等待冷却期
        vm.warp(block.timestamp + 15 * 60 + 1);
        
        uint256 tokenBalanceBefore = ytTokenA.balanceOf(user1);
        
        // 移除流动性
        uint256 amountOut = router.removeLiquidity(
            address(ytTokenA),
            ytLPBalance,
            0,
            user1
        );
        
        vm.stopPrank();
        uint256 expectedOut = 997 ether;  // 这里能够取出997是因为池子中只有一个用户，user1的997个ytLp代币价值1000USDY，卖出后获得997个YT-A代币
        assertEq(amountOut, expectedOut, "remove liquidity amount incorrect");
        assertEq(ytTokenA.balanceOf(user1), tokenBalanceBefore + expectedOut, "user1 final balance incorrect");
        assertEq(ytlp.balanceOf(user1), 0, "ytLP should be burned");
        assertEq(ytlp.totalSupply(), 0, "ytLP supply should be 0");
    }
    
    function test_10_RemoveLiquidityCooldownProtection() public {
        uint256 amount = 1000 ether;
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1);
        
        // 不等待冷却期，直接移除
        vm.expectRevert(abi.encodeWithSignature("CooldownNotPassed()"));
        router.removeLiquidity(address(ytTokenA), ytLPBalance, 0, user1);
        
        vm.stopPrank();
    }
    
    // ==================== 4. Swap测试 ====================
    
    function test_11_SwapYTTokens() public {
        // 先为池子添加流动性
        uint256 liquidityAmount = 2000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenA), liquidityAmount, 0, 0);
        
        ytTokenB.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenB), liquidityAmount, 0, 0);
        vm.stopPrank();
        
        // Swap测试
        uint256 swapAmount = 100 ether;
        
        vm.startPrank(user2);
        ytTokenA.approve(address(router), swapAmount);
        
        uint256 balanceBBefore = ytTokenB.balanceOf(user2);
        
        uint256 amountOut = router.swapYT(
            address(ytTokenA),
            address(ytTokenB),
            swapAmount,
            0,
            user2
        );
        
        vm.stopPrank();
        
        uint256 expectedOut = 99.7 ether;
        assertEq(amountOut, expectedOut, "swap amount incorrect");
        assertEq(ytTokenB.balanceOf(user2), balanceBBefore + expectedOut, "user2 balance incorrect");
    }
    
    function test_12_SwapSameTokenReverts() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        
        ytTokenA.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("SameToken()"));
        router.swapYT(address(ytTokenA), address(ytTokenA), 100 ether, 0, user1);
        
        vm.stopPrank();
    }
    
    // ==================== 5. 价格测试 ====================
    
    function test_13_PriceWithoutSpread() public view {
        // 未设置价差时
        uint256 price = priceFeed.getPrice(address(ytTokenA), true);
        assertEq(price, 1e30, "price should be $1.00");
        
        uint256 maxPrice = priceFeed.getMaxPrice(address(ytTokenA));
        uint256 minPrice = priceFeed.getMinPrice(address(ytTokenA));
        
        assertEq(maxPrice, 1e30, "maxPrice should equal base price");
        assertEq(minPrice, 1e30, "minPrice should equal base price");
    }
    
    function test_14_PriceWithSpread() public {
        // 设置0.2%价差 (20 bps)
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 20);
        
        uint256 basePrice = 1e30; // $1.00
        uint256 maxPrice = priceFeed.getMaxPrice(address(ytTokenA));
        uint256 minPrice = priceFeed.getMinPrice(address(ytTokenA));
        
        // MaxPrice = $1.00 × 1.002 = $1.002
        uint256 expectedMax = basePrice * 10020 / 10000;
        assertEq(maxPrice, expectedMax, "maxPrice with spread incorrect");
        
        // MinPrice = $1.00 × 0.998 = $0.998
        uint256 expectedMin = basePrice * 9980 / 10000;
        assertEq(minPrice, expectedMin, "minPrice with spread incorrect");
        
        // 清除价差设置
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 0);
    }
    
    function test_15_USDCPriceFromChainlink() public view {
        // USDC价格应该从Chainlink读取
        uint256 usdcPrice = priceFeed.getPrice(address(usdc), true);

        // 应该等于 $1.00 (转换为 1e30 精度)
        // Chainlink 返回 1e8，需要转换为 1e30: 1e8 * 1e22 = 1e30
        assertEq(usdcPrice, PRICE_PRECISION, "USDC price should be 1.0");
    }
    
    // ==================== 6. YTAssetVault特定功能测试 ====================
    
    function test_16_UpdateYTPrices() public {
        uint256 newYtPrice = 1.05e30;    // $1.05
        
        // 通过factory更新价格（USDC价格从Chainlink获取，只更新ytPrice）
        factory.updateVaultPrices(address(ytTokenA), newYtPrice);
        
        assertEq(ytTokenA.ytPrice(), newYtPrice, "ytPrice update failed");
        
        // 重置价格
        factory.updateVaultPrices(address(ytTokenA), PRICE_PRECISION);
    }
    
    function test_17_BuyYTWithUSDC() public {
        uint256 usdcAmount = 1000 ether;
        
        vm.startPrank(user1);
        usdc.approve(address(ytTokenA), usdcAmount);
        
        uint256 ytBefore = ytTokenA.balanceOf(user1);
        uint256 ytReceived = ytTokenA.depositYT(usdcAmount);
        uint256 ytAfter = ytTokenA.balanceOf(user1);
        
        vm.stopPrank();
        
        // 价格都是1.0，应该1:1兑换
        assertEq(ytReceived, usdcAmount, "YT amount should equal USDC amount");
        assertEq(ytAfter - ytBefore, usdcAmount, "YT balance incorrect");
    }
    
    function test_18_HardCapProtection() public {
        // 获取当前totalSupply
        uint256 currentSupply = ytTokenA.totalSupply(); // 10000 ether
        
        // 通过factory设置hardCap为当前供应量 + 500（允许少量增加）
        uint256 newHardCap = currentSupply + 500 ether;
        factory.setHardCap(address(ytTokenA), newHardCap);
        
        vm.startPrank(user1);
        usdc.approve(address(ytTokenA), 1000 ether);
        
        // 尝试存入1000 ether会超过hardCap，应该revert
        vm.expectRevert(abi.encodeWithSignature("HardCapExceeded()"));
        ytTokenA.depositYT(1000 ether);
        
        vm.stopPrank();
        
        // 恢复hardCap
        factory.setHardCap(address(ytTokenA), 1000000 ether);
    }
    
    // ==================== 7. 权限测试 ====================
    
    function test_19_OnlyFactoryCanUpdatePrices() public {
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        ytTokenA.updatePrices(1e30);
        
        vm.stopPrank();
    }
    
    function test_20_OnlyGovCanSetWhitelist() public {
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        vault.setWhitelistedToken(address(0x123), 18, 1000, 1000000 ether, false);
        
        vm.stopPrank();
    }
    
    // ==================== 8. 完整流程测试 ====================
    
    function test_21_CompleteFlow() public {
        console.log("=== Complete Flow Test ===");
        
        // 步骤1: User1添加YT-A流动性
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        uint256 ytLP1 = router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        console.log("User1 added 1000 YT-A, received ytLP:", ytLP1);
        assertEq(ytLP1, 997 ether);
        vm.stopPrank();
        
        // 步骤2: User1添加YT-B流动性
        vm.startPrank(user1);
        ytTokenB.approve(address(router), 1000 ether);
        uint256 ytLP1b = router.addLiquidity(address(ytTokenB), 1000 ether, 0, 0);
        console.log("User1 added 1000 YT-B, received ytLP:", ytLP1b);
        assertEq(ytLP1b, 994.009 ether);
        vm.stopPrank();
        
        uint256 totalYtLP = ytlp.balanceOf(user1);
        console.log("User1 total ytLP:", totalYtLP);
        
        // 步骤3: User2执行Swap
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 100 ether);
        uint256 swapOut = router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        console.log("User2 swapped 100 YT-A, received YT-B:", swapOut);
        assertEq(swapOut, 99.7 ether);
        vm.stopPrank();
        
        // 步骤4: 等待冷却期后，User1移除流动性
        vm.warp(block.timestamp + 16 * 60);
        
        vm.startPrank(user1);
        uint256 removeAmount = totalYtLP / 2; // 移除一半
        uint256 tokenOut = router.removeLiquidity(address(ytTokenA), removeAmount, 0, user1);
        console.log("User1 removed half ytLP, received YT-A:", tokenOut);
        vm.stopPrank();
    }
    
    // ==================== 9. 手续费测试 ====================
    
    function test_22_SwapFeesAccumulation() public {
        // 添加初始流动性
        uint256 liquidityAmount = 2000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenA), liquidityAmount, 0, 0);
        
        ytTokenB.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenB), liquidityAmount, 0, 0);
        
        uint256 ytLPBefore = ytlp.balanceOf(user1);
        uint256 priceBefore = poolManager.getPrice(true);
        
        vm.stopPrank();
        
        // 执行swap累积手续费（使用user2）
        uint256 swapAmount = 500 ether;
        
        vm.startPrank(user2);
        
        // Swap 1: YT-A → YT-B
        ytTokenA.approve(address(router), swapAmount);
        router.swapYT(address(ytTokenA), address(ytTokenB), swapAmount, 0, user2);
        
        // Swap 2: YT-B → YT-A
        ytTokenB.approve(address(router), swapAmount);
        router.swapYT(address(ytTokenB), address(ytTokenA), swapAmount, 0, user2);
        
        vm.stopPrank();
        
        uint256 priceAfter = poolManager.getPrice(true);
        
        // ytLP价格应该增长（手续费留在池中）
        assertTrue(priceAfter > priceBefore, "ytLP price should increase");
        
        // user1的ytLP数量不变
        assertEq(ytlp.balanceOf(user1), ytLPBefore, "ytLP balance should not change");
    }
    
    function test_23_GetSwapFeeBasisPoints() public view {
        uint256 usdyAmount = 1000 ether;
        
        // YT代币之间互换
        uint256 feeBps = vault.getSwapFeeBasisPoints(
            address(ytTokenA),
            address(ytTokenB),
            usdyAmount
        );
        assertEq(feeBps, 30, "YT swap fee should be 30 bps");
        
        // 赎回费率
        uint256 redemptionFeeBps = vault.getRedemptionFeeBasisPoints(
            address(ytTokenA),
            usdyAmount
        );
        assertEq(redemptionFeeBps, 30, "redemption fee should be 30 bps");
    }
    
    // ==================== 10. 白名单管理测试 ====================
    
    function test_24_AddWhitelistToken() public {
        // 通过factory创建新的YTAssetVault
        address ytTokenDAddr = factory.createVault(
            "YT Token D",
            "YT-D",
            deployer,
            1000000 ether,
            address(usdc),
            block.timestamp + 365 days,
            PRICE_PRECISION,
            address(usdcPriceFeed)
        );
        YTAssetVault ytTokenD = YTAssetVault(ytTokenDAddr);
        
        // 铸造一些YT-D
        usdc.mint(deployer, 1000 ether);
        usdc.approve(address(ytTokenD), 1000 ether);
        ytTokenD.depositYT(1000 ether);
        
        // 添加到白名单
        vault.setWhitelistedToken(address(ytTokenD), 18, 1000, 10000000 ether, false);
        
        // 验证
        assertTrue(vault.whitelistedTokens(address(ytTokenD)), "should be whitelisted");
        assertEq(vault.tokenWeights(address(ytTokenD)), 1000, "weight incorrect");
        assertEq(vault.totalTokenWeights(), 10000, "total weight incorrect");
        
        // 初始化价格
        priceFeed.forceUpdatePrice(address(ytTokenD), 1e30);
        
        // 验证可以添加流动性
        vm.startPrank(deployer);
        ytTokenD.approve(address(router), 100 ether);
        uint256 ytLPReceived = router.addLiquidity(address(ytTokenD), 100 ether, 0, 0);
        vm.stopPrank();
        
        assertEq(ytLPReceived, 99.7 ether, "first liquidity for new token incorrect");
    }
    
    function test_25_RemoveWhitelistToken() public {
        // 确保池子是空的
        assertEq(vault.poolAmounts(address(ytTokenC)), 0, "pool should be empty");
        
        uint256 weightBefore = vault.totalTokenWeights();
        
        // 移除白名单
        vault.clearWhitelistedToken(address(ytTokenC));
        
        // 验证
        assertFalse(vault.whitelistedTokens(address(ytTokenC)), "should not be whitelisted");
        assertEq(vault.tokenWeights(address(ytTokenC)), 0, "weight should be 0");
        assertEq(vault.totalTokenWeights(), weightBefore - 2000, "total weight incorrect");
        
        // 验证无法添加流动性
        vm.startPrank(user1);
        ytTokenC.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("TokenNotWhitelisted()"));
        router.addLiquidity(address(ytTokenC), 100 ether, 0, 0);
        
        vm.stopPrank();
    }
    
    function test_26_UpdateTokenWeight() public {
        uint256 oldWeight = vault.tokenWeights(address(ytTokenA));
        assertEq(oldWeight, 4000);
        
        // 更新权重
        vault.setWhitelistedToken(address(ytTokenA), 18, 5000, 45000000 ether, false);
        
        // 验证
        assertEq(vault.tokenWeights(address(ytTokenA)), 5000, "updated weight incorrect");
        assertEq(vault.totalTokenWeights(), 10000, "total weight after update incorrect");
    }
    
    // ==================== 11. 查询函数测试 ====================
    
    function test_27_GetPoolValue() public {
        vm.startPrank(user1);
        
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        
        ytTokenB.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenB), 2000 ether, 0, 0);
        
        vm.stopPrank();
        
        // 获取池子总价值
        uint256 poolValue = vault.getPoolValue(true);
        
        // 池中有: 1000 YT-A + 2000 YT-B = $3000
        uint256 expectedValue = 3000 ether;
        assertEq(poolValue, expectedValue, "pool value incorrect");
    }
    
    function test_28_GetTargetUsdyAmount() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        uint256 totalUsdy = usdy.totalSupply();
        uint256 targetUsdy = vault.getTargetUsdyAmount(address(ytTokenA));
        
        // YT-A权重 4000, 总权重 9000
        uint256 expectedTarget = totalUsdy * 4000 / 9000;
        assertEq(targetUsdy, expectedTarget, "target usdy amount incorrect");
    }
    
    function test_29_GetAccountValue() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        vm.stopPrank();
        
        uint256 accountValue = router.getAccountValue(user1);
        
        // 账户价值应该接近1000 USDY
        assertTrue(accountValue >= 995 ether && accountValue <= 1005 ether, "account value should be around 1000");
    }
    
    // ==================== 12. 动态手续费测试 ====================
    
    function test_30_DynamicFeesDisabled() public view {
        assertFalse(vault.hasDynamicFees());
        
        uint256 feeBps = vault.getFeeBasisPoints(
            address(ytTokenA),
            1000 ether,
            30,
            50,
            true
        );
        
        assertEq(feeBps, 30, "should return base fee when dynamic disabled");
    }
    
    function test_31_DynamicFeesEnabled() public {
        vault.setDynamicFees(true);
        
        vm.startPrank(user1);
        
        // 大量添加YT-A
        ytTokenA.approve(address(router), 3000 ether);
        router.addLiquidity(address(ytTokenA), 3000 ether, 0, 0);
        
        // 少量添加YT-B
        ytTokenB.approve(address(router), 500 ether);
        router.addLiquidity(address(ytTokenB), 500 ether, 0, 0);
        
        vm.stopPrank();
        
        uint256 usdyAmount = 100 ether;
        
        // YT-A → YT-B (恶化平衡，费率更高)
        uint256 feeHigher = vault.getSwapFeeBasisPoints(
            address(ytTokenA),
            address(ytTokenB),
            usdyAmount
        );
        
        // YT-B → YT-A (改善平衡，费率更低)
        uint256 feeLower = vault.getSwapFeeBasisPoints(
            address(ytTokenB),
            address(ytTokenA),
            usdyAmount
        );
        
        assertTrue(feeHigher > 30, "fee should be higher when worsening balance");
        assertTrue(feeLower < 30, "fee should be lower when improving balance");
        
        vault.setDynamicFees(false);
    }
    
    // ==================== 13. 价格预言机测试 ====================
    
    function test_32_SetSpreadBasisPoints() public {
        uint256 spreadBps = 20;
        
        priceFeed.setSpreadBasisPoints(address(ytTokenA), spreadBps);
        
        assertEq(priceFeed.spreadBasisPoints(address(ytTokenA)), spreadBps);
    }
    
    function test_33_SpreadBasisPointsTooHigh() public {
        uint256 tooHighSpread = 300; // 3% > 最大2%
        
        vm.expectRevert(abi.encodeWithSignature("SpreadTooHigh()"));
        priceFeed.setSpreadBasisPoints(address(ytTokenA), tooHighSpread);
    }
    
    function test_34_BatchSetSpread() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(ytTokenA);
        tokens[1] = address(ytTokenB);
        tokens[2] = address(ytTokenC);
        
        uint256[] memory spreads = new uint256[](3);
        spreads[0] = 10;
        spreads[1] = 20;
        spreads[2] = 30;
        
        priceFeed.setSpreadBasisPointsForMultiple(tokens, spreads);
        
        assertEq(priceFeed.spreadBasisPoints(address(ytTokenA)), 10);
        assertEq(priceFeed.spreadBasisPoints(address(ytTokenB)), 20);
        assertEq(priceFeed.spreadBasisPoints(address(ytTokenC)), 30);
        
        // 清除
        spreads[0] = 0;
        spreads[1] = 0;
        spreads[2] = 0;
        priceFeed.setSpreadBasisPointsForMultiple(tokens, spreads);
    }
    
    function test_35_PriceProtectionMaxChange() public {
        priceFeed.forceUpdatePrice(address(ytTokenA), 1e30);
        
        uint256 tooHighPrice = 1.06e30; // +6%
        
        priceFeed.forceUpdatePrice(address(ytTokenA), tooHighPrice);
        
        assertEq(priceFeed.maxPriceChangeBps(), 500, "max change should be 5%");
    }
    
    // ==================== 14. AUM计算测试 ====================
    
    function test_36_GetAumWithMaximise() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        uint256 aumMax = poolManager.getAumInUsdy(true);
        uint256 aumMin = poolManager.getAumInUsdy(false);
        
        // 无价差时，两者应该相等
        assertEq(aumMax, aumMin, "aum should be equal without spread");
        assertEq(aumMax, 1000 ether, "aum should be $1000");
    }
    
    function test_37_GetAumWithSpread() public {
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 20); // 0.2%
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        uint256 aumMax = poolManager.getAumInUsdy(true);
        uint256 aumMin = poolManager.getAumInUsdy(false);
        
        assertEq(aumMax, 1002 ether, "aum max with spread incorrect");
        assertEq(aumMin, 998 ether, "aum min with spread incorrect");
        
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 0);
    }
    
    // ==================== 15. 多用户场景测试 ====================
    
    function test_38_MultipleUsersAddLiquidity() public {
        // User1 添加
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        uint256 ytLP1 = router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        // User2 添加
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 2000 ether);
        uint256 ytLP2 = router.addLiquidity(address(ytTokenA), 2000 ether, 0, 0);
        vm.stopPrank();
        
        assertEq(ytLP1, 997 ether, "user1 ytLP incorrect");
        assertEq(ytLP2, 1988.018 ether, "user2 ytLP incorrect");
        
        // 份额比例
        uint256 total = ytlp.totalSupply();
        uint256 user1Share = ytLP1 * 10000 / total;
        uint256 user2Share = ytLP2 * 10000 / total;
        
        assertApproxEqAbs(user1Share, 3340, 1, "user1 share incorrect");
        assertApproxEqAbs(user2Share, 6660, 1, "user2 share incorrect");
    }
    
    function test_39_RemoveLiquidityPartial() public {
        uint256 addAmount = 1000 ether;
        vm.startPrank(user1);
        ytTokenA.approve(address(router), addAmount);
        router.addLiquidity(address(ytTokenA), addAmount, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1);
        uint256 removeAmount = ytLPBalance / 2;
        
        vm.warp(block.timestamp + 15 * 60 + 1);
        
        uint256 amountOut = router.removeLiquidity(
            address(ytTokenA),
            removeAmount,
            0,
            user1
        );
        
        vm.stopPrank();
        
        uint256 expectedOut = 498.5 ether;
        assertEq(amountOut, expectedOut, "partial remove amount incorrect");
        assertEq(ytlp.balanceOf(user1), removeAmount, "remaining ytLP incorrect");
    }
    
    // ==================== 16. 安全功能测试 ====================
    
    function test_40_EmergencyMode() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        vault.setEmergencyMode(true);
        
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("EmergencyMode()"));
        router.addLiquidity(address(ytTokenA), 100 ether, 0, 0);
        
        vm.expectRevert(abi.encodeWithSignature("EmergencyMode()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        
        vm.stopPrank();
        
        vault.setEmergencyMode(false);
    }
    
    function test_41_SwapDisabled() public {
        vault.setSwapEnabled(false);
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        
        vm.expectRevert(abi.encodeWithSignature("SwapDisabled()"));
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        
        vm.stopPrank();
        
        vault.setSwapEnabled(true);
    }
    
    function test_42_MaxSwapAmount() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenA), 2000 ether, 0, 0);
        
        ytTokenB.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenB), 2000 ether, 0, 0);
        vm.stopPrank();
        
        vault.setMaxSwapAmount(address(ytTokenA), 50 ether);
        
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("AmountExceedsLimit()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        
        vm.stopPrank();
        
        vault.setMaxSwapAmount(address(ytTokenA), 0);
    }
    
    // ==================== 17. 边界条件测试 ====================
    
    function test_43_AddZeroAmountReverts() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 0);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        router.addLiquidity(address(ytTokenA), 0, 0, 0);
        
        vm.stopPrank();
    }
    
    function test_44_RemoveZeroAmountReverts() public {
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        router.removeLiquidity(address(ytTokenA), 0, 0, user1);
        
        vm.stopPrank();
    }
    
    function test_45_SwapZeroAmountReverts() public {
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), 0, 0, user1);
        
        vm.stopPrank();
    }
    
    function test_46_SwapUnwhitelistedTokenReverts() public {
        // 通过factory创建新的YTAssetVault
        address ytTokenDAddr = factory.createVault(
            "YT Token D",
            "YT-D",
            deployer,
            1000000 ether,
            address(usdc),
            block.timestamp + 365 days,
            PRICE_PRECISION,
            address(usdcPriceFeed)
        );
        YTAssetVault ytTokenD = YTAssetVault(ytTokenDAddr);
        
        usdc.mint(user1, 500 ether);
        
        vm.startPrank(user1);
        usdc.approve(address(ytTokenD), 500 ether);
        ytTokenD.depositYT(500 ether);
        
        // 添加YT-A流动性
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        
        // 尝试swap未白名单的代币
        ytTokenD.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("TokenNotWhitelisted()"));
        router.swapYT(address(ytTokenD), address(ytTokenA), 100 ether, 0, user1);
        
        vm.stopPrank();
    }
    
    // ==================== 18. 费用精确计算测试 ====================
    
    function test_47_ExactFeeCalculation() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        
        uint256 poolAmountBefore = vault.poolAmounts(address(ytTokenA));
        uint256 usdyBefore = vault.usdyAmounts(address(ytTokenA));
        
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        
        vm.stopPrank();
        
        uint256 poolAmountAfter = vault.poolAmounts(address(ytTokenA));
        uint256 usdyAfter = vault.usdyAmounts(address(ytTokenA));
        
        // 池子应该收到全部代币
        assertEq(poolAmountAfter - poolAmountBefore, amount, "pool should receive full amount");
        
        // USDY债务只记录扣费后的
        assertEq(usdyAfter - usdyBefore, 997 ether, "usdy debt incorrect");
    }
    
    function test_48_RedemptionFeeCalculation() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1);
        
        vm.warp(block.timestamp + 16 * 60);
        
        uint256 poolAmountBefore = vault.poolAmounts(address(ytTokenA));
        
        router.removeLiquidity(address(ytTokenA), ytLPBalance, 0, user1);
        
        vm.stopPrank();
        
        uint256 poolAmountAfter = vault.poolAmounts(address(ytTokenA));
        
        uint256 amountRemoved = poolAmountBefore - poolAmountAfter;
        assertEq(amountRemoved, 997 ether, "amount removed from pool incorrect");
        
        // 池子剩余：添加时的手续费 3 ether
        assertEq(poolAmountAfter, 3 ether, "remaining pool incorrect");
    }
    
    // ==================== 19. ytLP价格增长测试 ====================
    
    function test_49_YtLPPriceGrowthFromFees() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenA), 2000 ether, 0, 0);
        
        ytTokenB.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenB), 2000 ether, 0, 0);
        vm.stopPrank();
        
        uint256 priceBefore = poolManager.getPrice(true);
        uint256 supplyBefore = ytlp.totalSupply();
        
        console.log("Price before swaps:", priceBefore);
        console.log("Supply:", supplyBefore);
        
        // 执行多次swap累积手续费
        vm.startPrank(user1);
        
        for (uint i = 0; i < 10; i++) {
            ytTokenA.approve(address(router), 100 ether);
            router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
            
            ytTokenB.approve(address(router), 100 ether);
            router.swapYT(address(ytTokenB), address(ytTokenA), 100 ether, 0, user2);
        }
        
        vm.stopPrank();
        
        uint256 priceAfter = poolManager.getPrice(true);
        uint256 supplyAfter = ytlp.totalSupply();
        
        console.log("Price after swaps:", priceAfter);
        
        assertEq(supplyAfter, supplyBefore, "supply should not change");
        assertTrue(priceAfter > priceBefore, "price should increase");
        
        uint256 priceIncrease = (priceAfter - priceBefore) * 10000 / priceBefore;
        console.log("Price increase (bps):", priceIncrease);
        
        assertTrue(priceIncrease >= 10 && priceIncrease <= 30, "price increase should be 10-30 bps");
    }
    
    // ==================== 20. 价格查询测试 ====================
    
    function test_50_GetPriceFromVault() public view {
        uint256 price = vault.getPrice(address(ytTokenA), true);
        assertEq(price, 1e30, "vault price incorrect");
        
        uint256 maxPrice = vault.getMaxPrice(address(ytTokenA));
        uint256 minPrice = vault.getMinPrice(address(ytTokenA));
        
        assertEq(maxPrice, 1e30);
        assertEq(minPrice, 1e30);
    }
    
    function test_51_GetPriceInfo() public view {
        (
            uint256 currentPrice,
            ,
            uint256 maxPrice,
            uint256 minPrice,
            uint256 spread
        ) = priceFeed.getPriceInfo(address(ytTokenA));
        
        assertEq(currentPrice, 1e30, "current price incorrect");
        assertEq(maxPrice, 1e30, "max price incorrect");
        assertEq(minPrice, 1e30, "min price incorrect");
        assertEq(spread, 0, "spread should be 0");
    }
    
    function test_52_YtLPPriceCalculation() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        vm.stopPrank();
        
        uint256 ytLPPrice = poolManager.getPrice(true);
        
        assertTrue(ytLPPrice > 1 ether, "ytLP price should be > $1");
        assertTrue(ytLPPrice < 1.01 ether, "ytLP price should be < $1.01");
    }
    
    function test_53_AddLiquidityWithSpread() public {
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 20); // 0.2%
        
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        
        uint256 ytLPReceived = router.addLiquidity(address(ytTokenA), amount, 0, 0);
        
        vm.stopPrank();
        
        uint256 expectedYtLP = 995.006 ether;
        assertEq(ytLPReceived, expectedYtLP, "ytLP with spread incorrect");
        
        priceFeed.setSpreadBasisPoints(address(ytTokenA), 0);
    }
    
    function test_54_RemoveLiquiditySlippageProtection() public {
        uint256 amount = 1000 ether;
        vm.startPrank(user1);
        ytTokenA.approve(address(router), amount);
        router.addLiquidity(address(ytTokenA), amount, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1);
        
        vm.warp(block.timestamp + 15 * 60 + 1);
        
        uint256 tooHighMinOut = 2000 ether;
        
        vm.expectRevert(abi.encodeWithSignature("InsufficientOutput()"));
        router.removeLiquidity(address(ytTokenA), ytLPBalance, tooHighMinOut, user1);
        
        vm.stopPrank();
    }
    
    function test_55_SwapSlippageProtection() public {
        uint256 liquidityAmount = 2000 ether;
        
        vm.startPrank(user1);
        ytTokenA.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenA), liquidityAmount, 0, 0);
        
        ytTokenB.approve(address(router), liquidityAmount);
        router.addLiquidity(address(ytTokenB), liquidityAmount, 0, 0);
        vm.stopPrank();
        
        uint256 swapAmount = 100 ether;
        uint256 tooHighMinOut = 150 ether;
        
        vm.startPrank(user2);
        ytTokenA.approve(address(router), swapAmount);
        
        vm.expectRevert(abi.encodeWithSignature("InsufficientOutput()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), swapAmount, tooHighMinOut, user2);
        
        vm.stopPrank();
    }
    
    function test_56_OnlyHandlerCanAddLiquidity() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(poolManager), 1000 ether);
        
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        poolManager.addLiquidityForAccount(
            user1,
            user1,
            address(ytTokenA),
            1000 ether,
            0,
            0
        );
        
        vm.stopPrank();
    }
    
    function test_57_OnlyPoolManagerCanBuyUSDY() public {
        vm.startPrank(user1);
        ytTokenA.approve(address(vault), 1000 ether);
        
        vm.expectRevert(abi.encodeWithSignature("OnlyPoolManager()"));
        vault.buyUSDY(address(ytTokenA), user1);
        
        vm.stopPrank();
    }
    
    function test_58_OnlyGovCanSetFees() public {
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        vault.setSwapFees(40, 5, 60, 25);
        
        vm.stopPrank();
    }
    
    function test_59_OnlyKeeperCanUpdatePrice() public {
        // 非keeper和非gov不能调用updatePrice
        vm.startPrank(user1);
        
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        priceFeed.updatePrice(address(ytTokenA));
        
        vm.stopPrank();
    }
    
    function test_60_SetKeeperPermission() public {
        // 设置user1为keeper
        priceFeed.setKeeper(user1, true);
        assertTrue(priceFeed.isKeeper(user1), "user1 should be keeper");
        
        // keeper可以调用updatePrice
        vm.startPrank(user1);
        uint256 price = priceFeed.updatePrice(address(ytTokenA));
        vm.stopPrank();
        
        assertEq(price, PRICE_PRECISION, "price should be updated");
        
        // 移除keeper权限
        priceFeed.setKeeper(user1, false);
        assertFalse(priceFeed.isKeeper(user1), "user1 should not be keeper");
        
        // 移除后不能调用
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        priceFeed.updatePrice(address(ytTokenA));
        vm.stopPrank();
    }
    
    function test_61_GovCanAlwaysUpdatePrice() public {
        // gov可以直接调用updatePrice
        uint256 price = priceFeed.updatePrice(address(ytTokenA));
        assertEq(price, PRICE_PRECISION, "gov can update price");
    }
    
    // ==================== 21. YTRewardRouter 暂停功能测试 ====================
    
    function test_62_RouterPauseByGov() public {
        // Gov可以暂停
        router.pause();
        assertTrue(router.paused(), "router should be paused");
        
        // Gov可以恢复
        router.unpause();
        assertFalse(router.paused(), "router should be unpaused");
    }
    
    function test_63_OnlyGovCanPauseRouter() public {
        // User不能暂停
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        router.pause();
        vm.stopPrank();
        
        // User不能恢复
        router.pause(); // 由deployer暂停
        
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        router.unpause();
        vm.stopPrank();
        
        router.unpause(); // 恢复
    }
    
    function test_64_CannotAddLiquidityWhenRouterPaused() public {
        // 暂停router
        router.pause();
        
        // 尝试添加流动性应该失败
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        // 恢复后应该可以添加
        router.unpause();
        
        vm.startPrank(user1);
        uint256 ytLPReceived = router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        assertEq(ytLPReceived, 997 ether, "add liquidity should work after unpause");
    }
    
    function test_65_CannotRemoveLiquidityWhenRouterPaused() public {
        // 先添加流动性
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        
        uint256 ytLPBalance = ytlp.balanceOf(user1);
        
        // 等待冷却期
        vm.warp(block.timestamp + 15 * 60 + 1);
        vm.stopPrank();
        
        // 暂停router
        router.pause();
        
        // 尝试移除流动性应该失败
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.removeLiquidity(address(ytTokenA), ytLPBalance, 0, user1);
        vm.stopPrank();
        
        // 恢复后应该可以移除
        router.unpause();
        
        vm.startPrank(user1);
        uint256 amountOut = router.removeLiquidity(address(ytTokenA), ytLPBalance, 0, user1);
        vm.stopPrank();
        
        assertEq(amountOut, 997 ether, "remove liquidity should work after unpause");
    }
    
    function test_66_CannotSwapWhenRouterPaused() public {
        // 先添加流动性
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenA), 2000 ether, 0, 0);
        
        ytTokenB.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenB), 2000 ether, 0, 0);
        vm.stopPrank();
        
        // 暂停router
        router.pause();
        
        // 尝试swap应该失败
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 100 ether);
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        vm.stopPrank();
        
        // 恢复后应该可以swap
        router.unpause();
        
        vm.startPrank(user2);
        uint256 amountOut = router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        vm.stopPrank();
        
        assertEq(amountOut, 99.7 ether, "swap should work after unpause");
    }
    
    function test_67_QueryFunctionsWorkWhenRouterPaused() public {
        // 先添加流动性
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        vm.stopPrank();
        
        // 暂停router
        router.pause();
        
        // 查询函数应该仍然可用
        uint256 ytLPPrice = router.getYtLPPrice();
        assertTrue(ytLPPrice > 0, "getYtLPPrice should work when paused");
        
        uint256 accountValue = router.getAccountValue(user1);
        assertTrue(accountValue > 0, "getAccountValue should work when paused");
        
        // 验证返回的值是合理的
        assertTrue(ytLPPrice > 1 ether, "ytLP price should be > $1");
        assertTrue(accountValue >= 995 ether && accountValue <= 1005 ether, "account value should be around 1000");
    }
    
    function test_68_PauseRouterDoesNotAffectVaultDirectly() public {
        // 暂停router不影响直接通过vault操作
        router.pause();
        
        vm.startPrank(user1);
        ytTokenA.approve(address(vault), 1000 ether);
        
        // 直接通过poolManager添加流动性仍然失败（因为user1不是handler）
        vm.expectRevert(abi.encodeWithSignature("Forbidden()"));
        poolManager.addLiquidityForAccount(user1, user1, address(ytTokenA), 1000 ether, 0, 0);
        
        vm.stopPrank();
        
        router.unpause();
    }
    
    function test_69_CompleteFlowWithPauseResume() public {
        console.log("=== Complete Flow With Pause/Resume Test ===");
        
        // 步骤1: 添加流动性
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 1000 ether);
        uint256 ytLP1 = router.addLiquidity(address(ytTokenA), 1000 ether, 0, 0);
        console.log("Added liquidity, received ytLP:", ytLP1);
        vm.stopPrank();
        
        // 步骤2: 暂停router
        router.pause();
        console.log("Router paused");
        
        // 步骤3: 验证所有操作都被阻止
        vm.startPrank(user1);
        ytTokenB.approve(address(router), 1000 ether);
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.addLiquidity(address(ytTokenB), 1000 ether, 0, 0);
        console.log("Add liquidity blocked during pause");
        vm.stopPrank();
        
        // 步骤4: 恢复router
        router.unpause();
        console.log("Router unpaused");
        
        // 步骤5: 继续正常操作
        vm.startPrank(user1);
        uint256 ytLP2 = router.addLiquidity(address(ytTokenB), 1000 ether, 0, 0);
        console.log("Added liquidity after unpause, received ytLP:", ytLP2);
        vm.stopPrank();
        
        // 验证总余额
        uint256 totalYtLP = ytlp.balanceOf(user1);
        console.log("Total ytLP:", totalYtLP);
        assertEq(totalYtLP, ytLP1 + ytLP2, "total ytLP should be sum of both additions");
    }
    
    function test_70_EmergencyScenarioPauseEverything() public {
        console.log("=== Emergency Scenario: Pause Everything ===");
        
        // 先建立一些状态
        vm.startPrank(user1);
        ytTokenA.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenA), 2000 ether, 0, 0);
        
        ytTokenB.approve(address(router), 2000 ether);
        router.addLiquidity(address(ytTokenB), 2000 ether, 0, 0);
        vm.stopPrank();
        
        console.log("Initial liquidity added");
        
        // 模拟紧急情况：暂停router
        router.pause();
        console.log("Router paused for emergency");
        
        // 同时暂停vault (通过设置紧急模式)
        vault.setEmergencyMode(true);
        console.log("Vault emergency mode activated");
        
        // 验证所有操作都被阻止
        vm.startPrank(user2);
        ytTokenA.approve(address(router), 100 ether);
        
        // Router暂停阻止操作
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.addLiquidity(address(ytTokenA), 100 ether, 0, 0);
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        
        vm.stopPrank();
        
        console.log("All operations blocked during emergency");
        
        // 恢复系统
        router.unpause();
        vault.setEmergencyMode(false);
        console.log("System recovered from emergency");
        
        // 验证系统恢复正常
        vm.startPrank(user2);
        uint256 swapOut = router.swapYT(address(ytTokenA), address(ytTokenB), 100 ether, 0, user2);
        vm.stopPrank();
        
        assertEq(swapOut, 99.7 ether, "swap should work after recovery");
        console.log("System operational after recovery");
    }
    
    receive() external payable {}
}