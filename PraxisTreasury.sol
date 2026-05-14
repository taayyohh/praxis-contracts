// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//  ____  ____  ____    __    ___  _  _  ____  _  _
// (_  _)(  _ \( ___)  /__\  / __)( )( )(  _ \( \/ )
//   )(   )   / )__)  /(__)\  \__ \ )()( )   / \  /
//  (__) (_)\_)(____)(__)(__)  (___/(____)(_)\_) (__)
//
/// @title PraxisTreasury
/// @author @taayyohh
/// @notice Protocol treasury: receives ETH deploy fees, swaps to USDC via Velodrome,
///         and forwards USDC to an EtherFi Cash account on Optimism.
///         The EtherFi Cash card auto-pays for infrastructure (NameSilo domains, Hetzner servers).
/// @dev Owner-gated. Flow: ETH -> Velodrome -> USDC -> EtherFiSafe (auto-spendable via card).

/// @notice Minimal interface for Velodrome V2 Router on Optimism
interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Swap exact ETH for tokens along a route
    function swapExactETHForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Get the canonical WETH address
    function WETH() external view returns (address);
}

/// @notice Minimal ERC-20 interface for token approvals and balance checks
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract PraxisTreasury {
    // --- State ---

    /// @notice The deployer/owner address
    address public immutable owner;

    /// @notice Velodrome V2 Router contract on Optimism
    IVelodromeRouter public immutable velodromeRouter;

    /// @notice Velodrome default factory for route resolution
    address public immutable velodromeFactory;

    /// @notice EtherFi Cash account (receives USDC for card spending)
    address public immutable etherFiCashAccount;

    /// @notice WETH address on Optimism
    address public immutable weth;

    /// @notice USDC address on Optimism
    address public immutable usdc;

    /// @notice Slippage tolerance in basis points (max 500 = 5%)
    uint256 public slippageBps;

    /// @notice Swap deadline extension in seconds
    uint256 public deadlineExtension;

    /// @notice Whether the contract is paused
    bool public paused;

    /// @notice Reentrancy guard state
    uint256 private _locked;

    // --- Events ---

    /// @notice Emitted when ETH is deposited (e.g., deploy fees)
    event Deposited(address indexed sender, uint256 amount);

    /// @notice Emitted when ETH is swapped to USDC via Velodrome
    event SwappedToUSDC(uint256 ethAmount, uint256 usdcAmount);

    /// @notice Emitted when USDC is forwarded to the EtherFi Cash account
    event ForwardedToCash(address indexed cashAccount, uint256 usdcAmount);

    /// @notice Emitted when ETH is withdrawn from the treasury
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when an ERC-20 token is swept from the treasury
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the cash account address is updated
    event CashAccountUpdated(address oldAccount, address newAccount);

    /// @notice Emitted when the slippage tolerance is updated
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the swap deadline extension is updated
    event DeadlineExtensionUpdated(uint256 oldSeconds, uint256 newSeconds);

    /// @notice Emitted when the pause state changes
    event PausedStateChanged(bool isPaused);

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 0, "reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // --- Constructor ---

    /// @notice Deploy the PraxisTreasury contract
    /// @param _velodromeRouter Address of the Velodrome V2 Router on Optimism
    /// @param _velodromeFactory Address of the Velodrome default factory
    /// @param _etherFiCashAccount Address of the EtherFi Cash account on Optimism
    /// @param _weth Address of WETH on Optimism
    /// @param _usdc Address of USDC on Optimism
    /// @param _slippageBps Default slippage tolerance in basis points
    constructor(
        address _velodromeRouter,
        address _velodromeFactory,
        address _etherFiCashAccount,
        address _weth,
        address _usdc,
        uint256 _slippageBps
    ) {
        require(_velodromeRouter != address(0), "zero router");
        require(_velodromeFactory != address(0), "zero factory");
        require(_weth != address(0), "zero weth");
        require(_usdc != address(0), "zero usdc");
        require(_slippageBps > 0 && _slippageBps <= 500, "slippage 0.01-5%");

        owner = msg.sender;
        velodromeRouter = IVelodromeRouter(_velodromeRouter);
        velodromeFactory = _velodromeFactory;
        etherFiCashAccount = _etherFiCashAccount;
        weth = _weth;
        usdc = _usdc;
        slippageBps = _slippageBps;
        deadlineExtension = 300; // 5 minutes
    }

    // --- Receive ---

    /// @notice Accept ETH deposits (deploy fees)
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // --- Core functions ---

    /// @notice Swap ETH for USDC via Velodrome Router
    /// @param ethAmount The amount of ETH to swap
    /// @param minUsdcOut Minimum USDC to receive (slippage protection)
    /// @return usdcReceived The actual USDC amount received
    function swapETHToUSDC(uint256 ethAmount, uint256 minUsdcOut) external onlyOwner nonReentrant whenNotPaused returns (uint256 usdcReceived) {
        require(ethAmount > 0, "zero amount");
        require(ethAmount <= address(this).balance, "insufficient ETH");

        // Use actual balance change (router return value may not match for all pools)
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        _doSwap(ethAmount, minUsdcOut);
        usdcReceived = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        require(usdcReceived >= minUsdcOut, "slippage exceeded");
        emit SwappedToUSDC(ethAmount, usdcReceived);
    }

    /// @notice Forward USDC to the EtherFi Cash account
    /// @param amount The USDC amount to forward
    function forwardToCash(uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(amount > 0, "zero amount");
        address _cash = etherFiCashAccount;
        require(_cash != address(0), "cash account not set");

        uint256 balance = IERC20(usdc).balanceOf(address(this));
        require(balance >= amount, "insufficient USDC");

        require(IERC20(usdc).transfer(_cash, amount), "transfer failed");
        emit ForwardedToCash(_cash, amount);
    }

    /// @notice Swap ETH to USDC and forward to EtherFi Cash in one transaction
    /// @param ethAmount The amount of ETH to swap
    /// @param minUsdcOut Minimum USDC to receive (slippage protection)
    /// @return usdcForwarded The USDC amount sent to the cash account
    function swapAndForward(uint256 ethAmount, uint256 minUsdcOut) external onlyOwner nonReentrant whenNotPaused returns (uint256 usdcForwarded) {
        require(ethAmount > 0, "zero amount");
        require(ethAmount <= address(this).balance, "insufficient ETH");
        address _cash = etherFiCashAccount;
        require(_cash != address(0), "cash account not set");

        // Step 1: Swap ETH -> USDC via Velodrome (use actual balance change, not router return value)
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        _doSwap(ethAmount, minUsdcOut);
        usdcForwarded = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        require(usdcForwarded >= minUsdcOut, "slippage exceeded");
        emit SwappedToUSDC(ethAmount, usdcForwarded);

        // Step 2: Forward all USDC to cash account
        require(IERC20(usdc).transfer(_cash, usdcForwarded), "transfer failed");
        emit ForwardedToCash(_cash, usdcForwarded);
    }

    // --- Internal ---

    /// @dev Execute a WETH->USDC swap via Velodrome V2 volatile pool
    /// @param ethAmount Amount of ETH to swap
    /// @param minUsdcOut Minimum USDC output (slippage floor)
    /// @return usdcReceived The USDC amount received from the swap
    function _doSwap(uint256 ethAmount, uint256 minUsdcOut) internal returns (uint256 usdcReceived) {
        // Velodrome V2: route WETH -> USDC through the default factory (volatile pool)
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({
            from: weth,
            to: usdc,
            stable: false,
            factory: velodromeFactory
        });

        uint256 deadline = block.timestamp + deadlineExtension;
        uint256[] memory amounts = velodromeRouter.swapExactETHForTokens{value: ethAmount}(
            minUsdcOut,
            routes,
            address(this),
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
        require(usdcReceived >= minUsdcOut, "slippage exceeded");
    }

    // --- Owner admin ---

    /// @notice Withdraw ETH from the treasury
    function withdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        require(amount > 0, "zero amount");
        require(amount <= address(this).balance, "insufficient ETH");

        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @notice Sweep any ERC-20 token from the treasury
    function sweepToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), "zero token");
        require(to != address(0), "zero address");
        require(amount > 0, "zero amount");

        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "transfer failed");
        emit TokenSwept(token, to, amount);
    }

    /// @notice Pause or unpause the contract
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /// @notice Update slippage tolerance
    function setSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps > 0 && _bps <= 500, "slippage 0.01-5%");
        emit SlippageUpdated(slippageBps, _bps);
        slippageBps = _bps;
    }

    /// @notice Update swap deadline extension
    function setDeadlineExtension(uint256 _seconds) external onlyOwner {
        require(_seconds >= 60 && _seconds <= 3600, "60s-1h");
        emit DeadlineExtensionUpdated(deadlineExtension, _seconds);
        deadlineExtension = _seconds;
    }

    // --- Views ---

    /// @notice Get the ETH balance held by the treasury
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get the USDC balance held by the treasury
    function usdcBalance() external view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }
}
