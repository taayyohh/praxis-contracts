// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../PraxisTreasury.sol";

/// @dev Mock Velodrome Router that simulates swapExactETHForTokens
contract MockVelodromeRouter {
    address public usdc;
    address public wethAddr;
    uint256 public mockRate; // USDC per ETH (6 decimals)

    constructor(address _usdc, address _weth, uint256 _mockRate) {
        usdc = _usdc;
        wethAddr = _weth;
        mockRate = _mockRate;
    }

    function WETH() external view returns (address) {
        return wethAddr;
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        IVelodromeRouter.Route[] calldata /* routes */,
        address to,
        uint256 /* deadline */
    ) external payable returns (uint256[] memory amounts) {
        uint256 amountOut = (msg.value * mockRate) / 1 ether;
        require(amountOut >= amountOutMin, "mock: slippage");

        MockERC20(usdc).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = amountOut;
    }
}

/// @dev Mock ERC-20 token for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PraxisTreasuryTest is Test {
    event Deposited(address indexed sender, uint256 amount);
    event SwappedToUSDC(uint256 ethAmount, uint256 usdcAmount);
    event ForwardedToCash(address indexed cashAccount, uint256 usdcAmount);
    event Withdrawn(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event CashAccountUpdated(address oldAccount, address newAccount);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event DeadlineExtensionUpdated(uint256 oldSeconds, uint256 newSeconds);
    event PausedStateChanged(bool isPaused);

    PraxisTreasury treasury;
    MockERC20 mockUsdc;
    MockERC20 mockWeth;
    MockVelodromeRouter mockRouter;
    address cashAccount;
    address factory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant MOCK_RATE = 2000e6; // 2000 USDC per ETH

    function setUp() public {
        mockUsdc = new MockERC20("USD Coin", "USDC", 6);
        mockWeth = new MockERC20("Wrapped Ether", "WETH", 18);
        mockRouter = new MockVelodromeRouter(address(mockUsdc), address(mockWeth), MOCK_RATE);
        cashAccount = makeAddr("etherFiCash");
        factory = makeAddr("velodromeFactory");

        treasury = new PraxisTreasury(
            address(mockRouter),
            factory,
            cashAccount,
            address(mockWeth),
            address(mockUsdc),
            50 // 0.5% slippage
        );

        vm.deal(address(treasury), 100 ether);
        vm.deal(alice, 10 ether);
    }

    // ===== Constructor =====

    function test_constructor_sets_state() public view {
        assertEq(treasury.owner(), address(this));
        assertEq(address(treasury.velodromeRouter()), address(mockRouter));
        assertEq(treasury.velodromeFactory(), factory);
        assertEq(treasury.etherFiCashAccount(), cashAccount);
        assertEq(treasury.weth(), address(mockWeth));
        assertEq(treasury.usdc(), address(mockUsdc));
        assertEq(treasury.slippageBps(), 50);
        assertEq(treasury.deadlineExtension(), 300);
    }

    function test_constructor_zero_router_reverts() public {
        vm.expectRevert("zero router");
        new PraxisTreasury(address(0), factory, address(0), address(mockWeth), address(mockUsdc), 50);
    }

    function test_constructor_zero_factory_reverts() public {
        vm.expectRevert("zero factory");
        new PraxisTreasury(address(mockRouter), address(0), address(0), address(mockWeth), address(mockUsdc), 50);
    }

    function test_constructor_zero_weth_reverts() public {
        vm.expectRevert("zero weth");
        new PraxisTreasury(address(mockRouter), factory, address(0), address(0), address(mockUsdc), 50);
    }

    function test_constructor_zero_usdc_reverts() public {
        vm.expectRevert("zero usdc");
        new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(0), 50);
    }

    function test_constructor_slippage_too_high_reverts() public {
        vm.expectRevert("slippage 0.01-5%");
        new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), 501);
    }

    // ===== Receive =====

    function test_receive_eth() public {
        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(treasury.ethBalance(), 101 ether);
    }

    function test_receive_zero_eth() public {
        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, 0);

        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 0}("");
        assertTrue(ok);
    }

    // ===== swapETHToUSDC =====

    function test_swapETHToUSDC_success() public {
        uint256 ethAmount = 1 ether;
        uint256 expectedUsdc = 2000e6;

        vm.expectEmit(false, false, false, true);
        emit SwappedToUSDC(ethAmount, expectedUsdc);

        uint256 usdcReceived = treasury.swapETHToUSDC(ethAmount, 1900e6);
        assertEq(usdcReceived, expectedUsdc);
        assertEq(treasury.usdcBalance(), expectedUsdc);
    }

    function test_swapETHToUSDC_zero_amount_reverts() public {
        vm.expectRevert("zero amount");
        treasury.swapETHToUSDC(0, 0);
    }

    function test_swapETHToUSDC_insufficient_eth_reverts() public {
        vm.expectRevert("insufficient ETH");
        treasury.swapETHToUSDC(200 ether, 0);
    }

    function test_swapETHToUSDC_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.swapETHToUSDC(1 ether, 0);
    }

    // ===== forwardToCash =====

    function test_forwardToCash_success() public {
        treasury.swapETHToUSDC(1 ether, 1900e6);
        uint256 usdcBal = treasury.usdcBalance();

        vm.expectEmit(true, false, false, true);
        emit ForwardedToCash(cashAccount, usdcBal);

        treasury.forwardToCash(usdcBal);
        assertEq(treasury.usdcBalance(), 0);
        assertEq(mockUsdc.balanceOf(cashAccount), usdcBal);
    }

    function test_forwardToCash_zero_amount_reverts() public {
        vm.expectRevert("zero amount");
        treasury.forwardToCash(0);
    }

    function test_forwardToCash_insufficient_usdc_reverts() public {
        vm.expectRevert("insufficient USDC");
        treasury.forwardToCash(1000e6);
    }

    function test_forwardToCash_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.forwardToCash(100e6);
    }

    function test_forwardToCash_partial() public {
        treasury.swapETHToUSDC(1 ether, 1900e6);
        uint256 usdcBal = treasury.usdcBalance();

        treasury.forwardToCash(usdcBal / 2);
        assertEq(treasury.usdcBalance(), usdcBal / 2);
        assertEq(mockUsdc.balanceOf(cashAccount), usdcBal / 2);
    }

    // ===== swapAndForward =====

    function test_swapAndForward_success() public {
        uint256 ethAmount = 5 ether;
        uint256 expectedUsdc = 10000e6;

        vm.expectEmit(false, false, false, true);
        emit SwappedToUSDC(ethAmount, expectedUsdc);

        uint256 forwarded = treasury.swapAndForward(ethAmount, 9500e6);
        assertEq(forwarded, expectedUsdc);
        assertEq(treasury.usdcBalance(), 0);
        assertEq(mockUsdc.balanceOf(cashAccount), expectedUsdc);
    }

    function test_swapAndForward_zero_amount_reverts() public {
        vm.expectRevert("zero amount");
        treasury.swapAndForward(0, 0);
    }

    function test_swapAndForward_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.swapAndForward(1 ether, 0);
    }

    function test_swapAndForward_insufficient_eth_reverts() public {
        vm.expectRevert("insufficient ETH");
        treasury.swapAndForward(200 ether, 0);
    }

    // ===== withdrawETH =====

    function test_withdrawETH_success() public {
        uint256 bobBefore = bob.balance;

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(bob, 10 ether);

        treasury.withdrawETH(bob, 10 ether);
        assertEq(bob.balance, bobBefore + 10 ether);
    }

    function test_withdrawETH_zero_address_reverts() public {
        vm.expectRevert("zero address");
        treasury.withdrawETH(address(0), 1 ether);
    }

    function test_withdrawETH_zero_amount_reverts() public {
        vm.expectRevert("zero amount");
        treasury.withdrawETH(bob, 0);
    }

    function test_withdrawETH_insufficient_reverts() public {
        vm.expectRevert("insufficient ETH");
        treasury.withdrawETH(bob, 200 ether);
    }

    function test_withdrawETH_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.withdrawETH(alice, 1 ether);
    }

    // ===== sweepToken =====

    function test_sweepToken_success() public {
        treasury.swapETHToUSDC(1 ether, 1900e6);
        uint256 usdcBal = treasury.usdcBalance();

        vm.expectEmit(true, true, false, true);
        emit TokenSwept(address(mockUsdc), bob, usdcBal);

        treasury.sweepToken(address(mockUsdc), bob, usdcBal);
        assertEq(mockUsdc.balanceOf(bob), usdcBal);
        assertEq(treasury.usdcBalance(), 0);
    }

    function test_sweepToken_zero_token_reverts() public {
        vm.expectRevert("zero token");
        treasury.sweepToken(address(0), bob, 100);
    }

    function test_sweepToken_zero_address_reverts() public {
        vm.expectRevert("zero address");
        treasury.sweepToken(address(mockUsdc), address(0), 100);
    }

    function test_sweepToken_zero_amount_reverts() public {
        vm.expectRevert("zero amount");
        treasury.sweepToken(address(mockUsdc), bob, 0);
    }

    function test_sweepToken_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.sweepToken(address(mockUsdc), alice, 100);
    }

    function test_sweepToken_insufficient_balance_reverts() public {
        vm.expectRevert("insufficient balance");
        treasury.sweepToken(address(mockUsdc), bob, 1000e6);
    }

    // ===== Immutable config =====

    function test_immutable_velodromeFactory() public view {
        assertEq(treasury.velodromeFactory(), factory);
    }

    function test_immutable_etherFiCashAccount() public view {
        assertEq(treasury.etherFiCashAccount(), cashAccount);
    }

    function test_immutable_slippageBps() public view {
        assertEq(treasury.slippageBps(), 50);
    }

    function test_immutable_deadlineExtension() public view {
        assertEq(treasury.deadlineExtension(), 300);
    }

    function test_constructor_slippage_max_500bps() public {
        new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), 500);

        vm.expectRevert("slippage 0.01-5%");
        new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), 501);

        vm.expectRevert("slippage 0.01-5%");
        new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), 0);
    }

    // ===== Pause =====

    function test_setPaused() public {
        vm.expectEmit(false, false, false, true);
        emit PausedStateChanged(true);

        treasury.setPaused(true);
        assertTrue(treasury.paused());

        treasury.setPaused(false);
        assertFalse(treasury.paused());
    }

    function test_setPaused_not_owner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        treasury.setPaused(true);
    }

    function test_swapETHToUSDC_paused_reverts() public {
        treasury.setPaused(true);
        vm.expectRevert("paused");
        treasury.swapETHToUSDC(1 ether, 0);
    }

    function test_forwardToCash_paused_reverts() public {
        treasury.setPaused(true);
        vm.expectRevert("paused");
        treasury.forwardToCash(100e6);
    }

    function test_swapAndForward_paused_reverts() public {
        treasury.setPaused(true);
        vm.expectRevert("paused");
        treasury.swapAndForward(1 ether, 0);
    }

    function test_withdrawETH_works_when_paused() public {
        treasury.setPaused(true);
        treasury.withdrawETH(bob, 1 ether);
        assertEq(bob.balance, 1 ether);
    }

    function test_sweepToken_works_when_paused() public {
        treasury.swapETHToUSDC(1 ether, 1900e6);
        uint256 usdcBal = treasury.usdcBalance();

        treasury.setPaused(true);
        treasury.sweepToken(address(mockUsdc), bob, usdcBal);
        assertEq(mockUsdc.balanceOf(bob), usdcBal);
    }

    // ===== Reentrancy =====

    function test_withdrawETH_sequential_works() public {
        treasury.withdrawETH(bob, 1 ether);
        treasury.withdrawETH(bob, 1 ether);
        assertEq(bob.balance, 2 ether);
    }

    // ===== Views =====

    function test_ethBalance() public view {
        assertEq(treasury.ethBalance(), 100 ether);
    }

    function test_usdcBalance_zero() public view {
        assertEq(treasury.usdcBalance(), 0);
    }

    // ===== Full flow =====

    function test_full_flow_swap_then_forward() public {
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 5 ether}("");
        assertTrue(ok);

        uint256 usdcOut = treasury.swapETHToUSDC(5 ether, 9500e6);
        assertEq(usdcOut, 10000e6);

        treasury.forwardToCash(usdcOut);
        assertEq(treasury.usdcBalance(), 0);
        assertEq(mockUsdc.balanceOf(cashAccount), usdcOut);
    }

    function test_full_flow_swap_and_forward_combined() public {
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 2 ether}("");
        assertTrue(ok);

        uint256 forwarded = treasury.swapAndForward(2 ether, 3800e6);
        assertEq(forwarded, 4000e6);
        assertEq(treasury.usdcBalance(), 0);
        assertEq(mockUsdc.balanceOf(cashAccount), 4000e6);
    }

    // ===== Fuzz tests =====

    function testFuzz_swapETHToUSDC(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 1, 100 ether);
        uint256 expectedUsdc = (ethAmount * MOCK_RATE) / 1 ether;

        uint256 usdcReceived = treasury.swapETHToUSDC(ethAmount, 0);
        assertEq(usdcReceived, expectedUsdc);
    }

    function testFuzz_constructor_slippage(uint256 bps) public {
        if (bps == 0 || bps > 500) {
            vm.expectRevert("slippage 0.01-5%");
            new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), bps);
        } else {
            PraxisTreasury t = new PraxisTreasury(address(mockRouter), factory, address(0), address(mockWeth), address(mockUsdc), bps);
            assertEq(t.slippageBps(), bps);
        }
    }
}
