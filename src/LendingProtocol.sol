// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title LendingProtocol
 * @notice A DeFi lending and borrowing protocol that allows users to:
 * - Deposit tokens to earn interest
 * - Borrow tokens against their deposited collateral
 * - Use off-chain signatures for gasless operations
 * - Manage collateralization ratios and liquidation
 */
contract LendingProtocol is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Structs
    struct User {
        uint256 totalDeposited; // Total amount deposited by user
        uint256 totalBorrowed; // Total amount borrowed by user
        uint256 lastUpdateTime; // Last time user's data was updated
        bool isActive; // Whether user has active positions
    }

    struct Market {
        IERC20 token; // The token being lent/borrowed
        uint256 totalSupply; // Total amount supplied to this market
        uint256 totalBorrow; // Total amount borrowed from this market
        uint256 supplyRate; // Current supply rate (APY in basis points)
        uint256 borrowRate; // Current borrow rate (APY in basis points)
        uint256 collateralFactor; // Collateral factor (0-10000, where 10000 = 100%)
        bool isActive; // Whether this market is active
    }

    struct SignatureData {
        uint256 nonce; // Unique nonce for signature
        uint256 deadline; // Signature expiration time
        bytes signature; // ECDSA signature
    }

    // State variables
    mapping(address => User) public users;
    mapping(address => mapping(address => uint256)) public userDeposits; // user => token => amount
    mapping(address => mapping(address => uint256)) public userBorrows; // user => token => amount
    mapping(address => Market) public markets;
    mapping(address => uint256) public userNonces;

    address[] public supportedTokens;
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% in basis points
    uint256 public constant LIQUIDATION_PENALTY = 500; // 5% in basis points
    uint256 public constant BASIS_POINTS = 10000;

    // Errors
    /// @notice A required address argument is the zero address.
    error ZeroAddress();
    /// @notice An amount argument is zero.
    error ZeroAmount();
    /// @notice The collateral factor is above `BASIS_POINTS`.
    error InvalidCollateralFactor();
    /// @notice A market already exists for the token.
    error MarketAlreadyExists();
    /// @notice The market for the token is not active.
    error MarketNotActive();
    /// @notice The caller deposited less than the requested withdrawal.
    error InsufficientDeposit();
    /// @notice The withdrawal would leave the position below the liquidation threshold.
    error WithdrawalUnsafe();
    /// @notice The market does not hold enough supply for the borrow.
    error InsufficientLiquidity();
    /// @notice The borrow would exceed the collateral limit.
    error BorrowExceedsCollateral();
    /// @notice The user owes less than the requested repayment.
    error InsufficientBorrow();
    /// @notice The signature deadline has passed.
    error SignatureExpired();
    /// @notice The signature nonce is not the user's current nonce.
    error InvalidNonce();
    /// @notice The recovered signer is not the caller.
    error InvalidSignature();
    /// @notice The user owes less than the amount to liquidate.
    error InsufficientBorrowToLiquidate();
    /// @notice The position is not below the liquidation threshold.
    error NotLiquidatable();
    /// @notice The user has no collateral to seize.
    error NoCollateralToSeize();
    /// @notice The best collateral does not cover the amount to seize.
    error InsufficientCollateral();

    // Events
    /// @notice Emitted when a market is added.
    event MarketAdded(address indexed token, uint256 collateralFactor);
    /// @notice Emitted when a market collateral factor changes.
    event MarketUpdated(address indexed token, uint256 collateralFactor);
    /// @notice Emitted when `user` deposits `amount` of `token`.
    event Deposit(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` withdraws `amount` of `token`.
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` borrows `amount` of `token`.
    event Borrow(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` repays `amount` of `token`.
    event Repay(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `liquidator` repays `amount` of `token` debt of `user`.
    event Liquidate(address indexed liquidator, address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when a market supply and borrow rates change.
    event RatesUpdated(address indexed token, uint256 supplyRate, uint256 borrowRate);
    /// @notice Emitted when the owner recovers tokens.
    event EmergencyRecovered(address indexed token, address indexed to, uint256 amount);

    // Modifiers
    /// @notice Reverts unless the market for `token` is active.
    modifier onlyActiveMarket(address token) {
        if (!markets[token].isActive) revert MarketNotActive();
        _;
    }

    /// @notice Checks deadline and nonce of `sigData` and bumps the caller nonce after the function body.
    modifier onlyValidSignature(SignatureData calldata sigData) {
        if (block.timestamp > sigData.deadline) revert SignatureExpired();
        if (userNonces[msg.sender] != sigData.nonce) revert InvalidNonce();
        _;
        userNonces[msg.sender]++;
    }

    /// @notice Deploys the protocol; the deployer becomes the owner.
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Add a new market to the protocol
     * @param token The ERC20 token to add
     * @param collateralFactor The collateral factor for this token (0-10000)
     * @param initialSupplyRate Initial supply rate in basis points
     * @param initialBorrowRate Initial borrow rate in basis points
     */
    function addMarket(address token, uint256 collateralFactor, uint256 initialSupplyRate, uint256 initialBorrowRate)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (collateralFactor > BASIS_POINTS) revert InvalidCollateralFactor();
        if (markets[token].isActive) revert MarketAlreadyExists();

        markets[token] = Market({
            token: IERC20(token),
            totalSupply: 0,
            totalBorrow: 0,
            supplyRate: initialSupplyRate,
            borrowRate: initialBorrowRate,
            collateralFactor: collateralFactor,
            isActive: true
        });

        supportedTokens.push(token);
        emit MarketAdded(token, collateralFactor);
    }

    /**
     * @notice Update market parameters
     * @param token The token address
     * @param collateralFactor New collateral factor
     * @param supplyRate New supply rate
     * @param borrowRate New borrow rate
     */
    function updateMarket(address token, uint256 collateralFactor, uint256 supplyRate, uint256 borrowRate)
        external
        onlyOwner
        onlyActiveMarket(token)
    {
        if (collateralFactor > BASIS_POINTS) revert InvalidCollateralFactor();

        markets[token].collateralFactor = collateralFactor;
        markets[token].supplyRate = supplyRate;
        markets[token].borrowRate = borrowRate;

        emit MarketUpdated(token, collateralFactor);
        emit RatesUpdated(token, supplyRate, borrowRate);
    }

    /**
     * @notice Deposit tokens to earn interest
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();

        userDeposits[msg.sender][token] += amount;
        users[msg.sender].totalDeposited += amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[token].totalSupply += amount;

        // Interaction last (Checks-Effects-Interactions)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw deposited tokens
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();
        if (userDeposits[msg.sender][token] < amount) revert InsufficientDeposit();
        if (!canWithdraw(msg.sender, token, amount)) revert WithdrawalUnsafe();

        userDeposits[msg.sender][token] -= amount;
        users[msg.sender].totalDeposited -= amount;
        users[msg.sender].lastUpdateTime = block.timestamp;

        if (users[msg.sender].totalDeposited == 0) {
            users[msg.sender].isActive = false;
        }

        markets[token].totalSupply -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /**
     * @notice Borrow tokens against deposited collateral
     * @param token The token to borrow
     * @param amount The amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();
        if (markets[token].totalSupply < amount) revert InsufficientLiquidity();
        if (!canBorrow(msg.sender, token, amount)) revert BorrowExceedsCollateral();

        userBorrows[msg.sender][token] += amount;
        users[msg.sender].totalBorrowed += amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[token].totalBorrow += amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }

    /**
     * @notice Repay borrowed tokens
     * @param token The token to repay
     * @param amount The amount to repay
     */
    function repay(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();
        if (userBorrows[msg.sender][token] < amount) revert InsufficientBorrow();

        userBorrows[msg.sender][token] -= amount;
        users[msg.sender].totalBorrowed -= amount;
        users[msg.sender].lastUpdateTime = block.timestamp;

        if (users[msg.sender].totalBorrowed == 0) {
            users[msg.sender].isActive = false;
        }

        markets[token].totalBorrow -= amount;

        // Interaction last (Checks-Effects-Interactions)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Repay(msg.sender, token, amount);
    }

    /**
     * @notice Gasless deposit using off-chain signature
     * @param token The token to deposit
     * @param amount The amount to deposit
     * @param sigData Signature data for verification
     */
    function depositWithSignature(address token, uint256 amount, SignatureData calldata sigData)
        external
        nonReentrant
        whenNotPaused
        onlyActiveMarket(token)
        onlyValidSignature(sigData)
    {
        if (amount == 0) revert ZeroAmount();

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked("deposit", token, amount, sigData.nonce, sigData.deadline));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ethSignedMessageHash.recover(sigData.signature);
        if (signer != msg.sender) revert InvalidSignature();

        userDeposits[msg.sender][token] += amount;
        users[msg.sender].totalDeposited += amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[token].totalSupply += amount;

        // Interaction last (Checks-Effects-Interactions)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param user The user to liquidate
     * @param token The token to liquidate
     * @param amount The amount to liquidate
     */
    function liquidate(address user, address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyActiveMarket(token)
    {
        if (amount == 0) revert ZeroAmount();
        if (userBorrows[user][token] < amount) revert InsufficientBorrowToLiquidate();
        if (!isLiquidatable(user)) revert NotLiquidatable();

        uint256 collateralToSeize = (amount * (BASIS_POINTS + LIQUIDATION_PENALTY)) / BASIS_POINTS;

        // Find collateral token to seize
        address collateralToken = findBestCollateral(user);
        if (collateralToken == address(0)) revert NoCollateralToSeize();
        if (userDeposits[user][collateralToken] < collateralToSeize) revert InsufficientCollateral();

        // Update user's borrow
        userBorrows[user][token] -= amount;
        users[user].totalBorrowed -= amount;
        markets[token].totalBorrow -= amount;

        // Seize collateral
        userDeposits[user][collateralToken] -= collateralToSeize;
        users[user].totalDeposited -= collateralToSeize;
        markets[collateralToken].totalSupply -= collateralToSeize;

        // Interactions last: take the debt tokens from the liquidator, then pay the seized collateral
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidate(msg.sender, user, token, amount);
    }

    /**
     * @notice Get user's current collateralization ratio
     * @param user The user address
     * @return ratio The collateralization ratio in basis points
     */
    function getCollateralizationRatio(address user) public view returns (uint256 ratio) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (markets[token].isActive) {
                uint256 depositAmount = userDeposits[user][token];
                uint256 borrowAmount = userBorrows[user][token];

                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * markets[token].collateralFactor) / BASIS_POINTS;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        if (totalBorrowValue == 0) return type(uint256).max;
        return (totalCollateralValue * BASIS_POINTS) / totalBorrowValue;
    }

    /**
     * @notice Check if a user can withdraw without making position unsafe
     * @param user The user address
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @return True if withdrawal is safe
     */
    function canWithdraw(address user, address token, uint256 amount) public view returns (bool) {
        uint256 currentRatio = getCollateralizationRatio(user);
        if (currentRatio == type(uint256).max) return true;

        // Calculate new ratio after withdrawal
        uint256 newCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address supportedToken = supportedTokens[i];
            if (markets[supportedToken].isActive) {
                uint256 depositAmount = userDeposits[user][supportedToken];
                uint256 borrowAmount = userBorrows[user][supportedToken];

                if (supportedToken == token) {
                    depositAmount = depositAmount > amount ? depositAmount - amount : 0;
                }

                if (depositAmount > 0) {
                    newCollateralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        uint256 newRatio = (newCollateralValue * BASIS_POINTS) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Check if a user can borrow additional tokens
     * @param user The user address
     * @param token The token to borrow
     * @param amount The amount to borrow
     * @return True if borrow is allowed
     */
    function canBorrow(address user, address token, uint256 amount) public view returns (bool) {
        uint256 currentRatio = getCollateralizationRatio(user);
        if (currentRatio == type(uint256).max) return true;

        // Calculate new ratio after borrow
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address supportedToken = supportedTokens[i];
            if (markets[supportedToken].isActive) {
                uint256 depositAmount = userDeposits[user][supportedToken];
                uint256 borrowAmount = userBorrows[user][supportedToken];

                if (supportedToken == token) {
                    borrowAmount += amount;
                }

                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        uint256 newRatio = (totalCollateralValue * BASIS_POINTS) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Check if a user's position is liquidatable
     * @param user The user address
     * @return True if position can be liquidated
     */
    function isLiquidatable(address user) public view returns (bool) {
        uint256 ratio = getCollateralizationRatio(user);
        return ratio < LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Find the best collateral token for liquidation
     * @param user The user address
     * @return The address of the best collateral token
     */
    function findBestCollateral(address user) internal view returns (address) {
        address bestToken = address(0);
        uint256 bestValue = 0;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (markets[token].isActive && userDeposits[user][token] > 0) {
                uint256 value = (userDeposits[user][token] * markets[token].collateralFactor) / BASIS_POINTS;
                if (value > bestValue) {
                    bestValue = value;
                    bestToken = token;
                }
            }
        }

        return bestToken;
    }

    /**
     * @notice Get user's nonce for signature verification
     * @param user The user address
     * @return The current nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return userNonces[user];
    }

    /**
     * @notice Get market information
     * @param token The token address
     * @return Market information
     */
    function getMarket(address token) external view returns (Market memory) {
        return markets[token];
    }

    /**
     * @notice Get user information
     * @param user The user address
     * @return User information
     */
    function getUser(address user) external view returns (User memory) {
        return users[user];
    }

    /**
     * @notice Get user's deposit for a specific token
     * @param user The user address
     * @param token The token address
     * @return The deposit amount
     */
    function getUserDeposit(address user, address token) external view returns (uint256) {
        return userDeposits[user][token];
    }

    /**
     * @notice Get user's borrow for a specific token
     * @param user The user address
     * @param token The token address
     * @return The borrow amount
     */
    function getUserBorrow(address user, address token) external view returns (uint256) {
        return userBorrows[user][token];
    }

    /**
     * @notice Get all supported tokens
     * @return Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Pause the protocol (emergency function)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the protocol
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token The token to recover
     * @param to The address to send tokens to
     * @param amount The amount to recover
     */
    function emergencyRecover(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovered(token, to, amount);
    }
}
