// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
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
    struct Market {
        IERC20 token; // The token being lent/borrowed
        uint256 totalSupply; // Total amount supplied to this market
        uint256 totalBorrow; // Total amount borrowed from this market
        uint256 ltv; // Max loan-to-value in basis points: how much can be borrowed against this collateral
        uint256 liquidationThreshold; // Basis points of this collateral that count for the health factor
        bool isActive; // Whether this market is active
    }

    /// @dev A user position valued in USD (8 decimals). Collateral is rounded down and debt rounded up.
    struct Position {
        uint256 ltvCollateralUsd; // sum(collateral * ltv): the most debt the position may hold
        uint256 thresholdCollateralUsd; // sum(collateral * liquidationThreshold): counted by the health factor
        uint256 debtUsd; // sum(debt)
    }

    struct SignatureData {
        uint256 nonce; // Unique nonce for signature
        uint256 deadline; // Signature expiration time
        bytes signature; // ECDSA signature
    }

    // State variables
    mapping(address => mapping(address => uint256)) public userDeposits; // user => token => amount
    mapping(address => mapping(address => uint256)) public userBorrows; // user => token => amount
    mapping(address => Market) public markets;
    mapping(address => uint256) public userNonces;

    /// @notice Price source: USD per whole token, 8 decimals. Immutable on purpose.
    IPriceOracle public immutable oracle;

    address[] public supportedTokens;
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% extra collateral for the liquidator, in basis points
    uint256 public constant CLOSE_FACTOR = 5000; // 50%: share of a debt that one liquidation may repay
    uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18; // below this health factor 100% can be repaid
    // Interest rate model (annual rates, 1e18 = 100%): a curve with a kink at the optimal utilization
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18;
    uint256 public constant BASE_BORROW_RATE = 0; // borrow rate at 0% utilization
    uint256 public constant RATE_SLOPE_1 = 0.04e18; // rate added going from 0% to the optimal utilization
    uint256 public constant RATE_SLOPE_2 = 0.75e18; // rate added going from the optimal utilization to 100%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant WAD = 1e18; // scale of the health factor: 1e18 means a health factor of 1

    // Errors
    /// @notice A required address argument is the zero address.
    error ZeroAddress();
    /// @notice An amount argument is zero.
    error ZeroAmount();
    /// @notice `ltv` is above `liquidationThreshold`, or `liquidationThreshold` with the liquidation bonus exceeds 100 %.
    error InvalidRiskParameters();
    /// @notice A market already exists for the token.
    error MarketAlreadyExists();
    /// @notice The market for the token is not active.
    error MarketNotActive();
    /// @notice The caller deposited less than the requested withdrawal.
    error InsufficientDeposit();
    /// @notice The withdrawal would leave the health factor below 1.
    error WithdrawalUnsafe();
    /// @notice The market does not have enough available liquidity (supplied minus borrowed) for the operation.
    error InsufficientLiquidity();
    /// @notice The borrow would exceed the borrowing power given by the LTV of the collateral.
    error BorrowExceedsCollateral();
    /// @notice The user owes less than the requested repayment.
    error InsufficientBorrow();
    /// @notice The signature deadline has passed.
    error SignatureExpired();
    /// @notice The signature nonce is not the user's current nonce.
    error InvalidNonce();
    /// @notice The recovered signer is not the caller.
    error InvalidSignature();
    /// @notice The user has no debt in the token to liquidate.
    error NoDebtToLiquidate();
    /// @notice The health factor of the position is not below 1.
    error NotLiquidatable();
    /// @notice The user does not hold enough of the chosen collateral to pay the liquidation bonus.
    error InsufficientCollateral();

    // Events
    /// @notice Emitted when a market is added.
    event MarketAdded(address indexed token, uint256 ltv, uint256 liquidationThreshold);
    /// @notice Emitted when the risk parameters of a market change.
    event MarketUpdated(address indexed token, uint256 ltv, uint256 liquidationThreshold);
    /// @notice Emitted when `user` deposits `amount` of `token`.
    event Deposit(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` withdraws `amount` of `token`.
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` borrows `amount` of `token`.
    event Borrow(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `user` repays `amount` of `token`.
    event Repay(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when `liquidator` repays `debtCovered` of `debtToken` for `user` and seizes `collateralSeized`.
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateralToken,
        address debtToken,
        uint256 debtCovered,
        uint256 collateralSeized
    );
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
    /// @param oracle_ The price oracle used to value every token in USD
    constructor(address oracle_) Ownable(msg.sender) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
    }

    /**
     * @notice Add a new market to the protocol
     * @param token The ERC20 token to add
     * @param ltv Max loan-to-value in basis points: how much can be borrowed against this token as collateral
     * @param liquidationThreshold Basis points of this token that count for the health factor (>= `ltv`)
     */
    function addMarket(address token, uint256 ltv, uint256 liquidationThreshold) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        _checkRiskParameters(ltv, liquidationThreshold);
        if (markets[token].isActive) revert MarketAlreadyExists();

        markets[token] = Market({
            token: IERC20(token),
            totalSupply: 0,
            totalBorrow: 0,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            isActive: true
        });

        supportedTokens.push(token);
        emit MarketAdded(token, ltv, liquidationThreshold);
    }

    /**
     * @notice Update market parameters
     * @param token The token address
     * @param ltv New max loan-to-value in basis points
     * @param liquidationThreshold New liquidation threshold in basis points (>= `ltv`)
     */
    function updateMarket(address token, uint256 ltv, uint256 liquidationThreshold)
        external
        onlyOwner
        onlyActiveMarket(token)
    {
        _checkRiskParameters(ltv, liquidationThreshold);

        markets[token].ltv = ltv;
        markets[token].liquidationThreshold = liquidationThreshold;

        emit MarketUpdated(token, ltv, liquidationThreshold);
    }

    /**
     * @notice Deposit tokens to earn interest
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();

        userDeposits[msg.sender][token] += amount;

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
        if (getAvailableLiquidity(token) < amount) revert InsufficientLiquidity();
        if (!canWithdraw(msg.sender, token, amount)) revert WithdrawalUnsafe();

        userDeposits[msg.sender][token] -= amount;

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
        if (getAvailableLiquidity(token) < amount) revert InsufficientLiquidity();
        if (!canBorrow(msg.sender, token, amount)) revert BorrowExceedsCollateral();

        userBorrows[msg.sender][token] += amount;

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

        markets[token].totalSupply += amount;

        // Interaction last (Checks-Effects-Interactions)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @notice Liquidate an unhealthy position: repay part of its debt and receive its collateral plus a bonus
     * @dev Requires a health factor below 1. At most `CLOSE_FACTOR` (50 %) of the user's debt in `debtToken` can be
     *      repaid, or all of it when the health factor is below `CLOSE_FACTOR_HF_THRESHOLD`; a larger `debtToCover`
     *      is capped. The collateral received is worth the repaid debt plus `LIQUIDATION_BONUS`, valued by the oracle.
     * @param collateralToken The collateral the liquidator chooses to receive
     * @param debtToken The debt token to repay
     * @param user The user to liquidate
     * @param debtToCover The amount of debt to repay, in `debtToken` units
     */
    function liquidate(address collateralToken, address debtToken, address user, uint256 debtToCover)
        external
        nonReentrant
        whenNotPaused
        onlyActiveMarket(collateralToken)
        onlyActiveMarket(debtToken)
    {
        if (debtToCover == 0) revert ZeroAmount();

        uint256 healthFactor = getHealthFactor(user);
        if (healthFactor >= WAD) revert NotLiquidatable();

        uint256 userDebt = userBorrows[user][debtToken];
        if (userDebt == 0) revert NoDebtToLiquidate();

        // Close factor: half of the debt (rounded up, so tiny debts can be cleared), or all of it when deep underwater
        uint256 maxDebtToCover = healthFactor < CLOSE_FACTOR_HF_THRESHOLD
            ? userDebt
            : Math.mulDiv(userDebt, CLOSE_FACTOR, BASIS_POINTS, Math.Rounding.Ceil);
        if (debtToCover > maxDebtToCover) debtToCover = maxDebtToCover;

        uint256 collateralSeized = _collateralToSeize(collateralToken, debtToken, debtToCover);
        if (userDeposits[user][collateralToken] < collateralSeized) revert InsufficientCollateral();

        // The contract must hold the collateral that is not lent out
        if (getAvailableLiquidity(collateralToken) < collateralSeized) revert InsufficientLiquidity();

        // Repay the user's debt
        userBorrows[user][debtToken] -= debtToCover;
        markets[debtToken].totalBorrow -= debtToCover;

        // Seize the collateral
        userDeposits[user][collateralToken] -= collateralSeized;
        markets[collateralToken].totalSupply -= collateralSeized;

        // Interactions last: take the debt tokens from the liquidator, then pay the seized collateral
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), debtToCover);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralSeized);

        emit Liquidate(msg.sender, user, collateralToken, debtToken, debtToCover, collateralSeized);
    }

    /**
     * @notice Health factor of a user: collateral weighted by each liquidation threshold, divided by the debt
     * @dev healthFactor = sum(collateralUsd * liquidationThreshold) / sum(debtUsd), scaled by `WAD`.
     *      Above `WAD` the position is healthy, below `WAD` it can be liquidated. With no debt it is `type(uint256).max`.
     * @param user The user address
     * @return The health factor, 1e18 = 1
     */
    function getHealthFactor(address user) public view returns (uint256) {
        Position memory position = _position(user, address(0), 0, 0);
        if (position.debtUsd == 0) return type(uint256).max;
        return Math.mulDiv(position.thresholdCollateralUsd, WAD, position.debtUsd);
    }

    /**
     * @notice Check if a user can withdraw without making the position liquidatable
     * @dev Uses the liquidation threshold: the health factor after the withdrawal must stay at 1 or more.
     * @param user The user address
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @return True if the withdrawal is safe
     */
    function canWithdraw(address user, address token, uint256 amount) public view returns (bool) {
        Position memory position = _position(user, token, amount, 0);
        return position.thresholdCollateralUsd >= position.debtUsd;
    }

    /**
     * @notice Check if a user can borrow additional tokens
     * @dev Uses the LTV: the debt after the borrow must not exceed the borrowing power. There is no special case
     *      for users without debt, so the first borrow is checked like any other.
     * @param user The user address
     * @param token The token to borrow
     * @param amount The amount to borrow
     * @return True if the borrow is allowed
     */
    function canBorrow(address user, address token, uint256 amount) public view returns (bool) {
        Position memory position = _position(user, token, 0, amount);
        return position.debtUsd <= position.ltvCollateralUsd;
    }

    /**
     * @notice Check if a user's position is liquidatable
     * @param user The user address
     * @return True if the health factor is below 1
     */
    function isLiquidatable(address user) public view returns (bool) {
        return getHealthFactor(user) < WAD;
    }

    /**
     * @notice Collateral a liquidator receives for repaying `debtToCover`: the debt plus the bonus, priced in USD
     * @dev collateral = debtToCover * (1 + bonus) * debtPrice / collateralPrice, adjusted for both token decimals.
     *      Rounded down, in favour of the borrower.
     * @param collateralToken The collateral token
     * @param debtToken The debt token
     * @param debtToCover The amount of debt repaid
     * @return The amount of `collateralToken` to seize
     */
    function _collateralToSeize(address collateralToken, address debtToken, uint256 debtToCover)
        internal
        view
        returns (uint256)
    {
        uint256 debtWithBonus = Math.mulDiv(debtToCover, BASIS_POINTS + LIQUIDATION_BONUS, BASIS_POINTS);
        uint256 valueUsd = _valueInUsd(debtToken, debtWithBonus, Math.Rounding.Floor);
        return
            Math.mulDiv(
                valueUsd, 10 ** IERC20Metadata(collateralToken).decimals(), oracle.getAssetPrice(collateralToken)
            );
    }

    /**
     * @notice Value a user position in USD, optionally simulating a pending withdrawal or borrow of one token
     * @dev Collateral is rounded down and debt is rounded up, always in favour of the protocol.
     * @param user The user address
     * @param token The token affected by the simulated operation (ignored when both amounts are 0)
     * @param withdrawn Amount of `token` that would be withdrawn
     * @param borrowed Amount of `token` that would be borrowed
     * @return position The position in USD with 8 decimals
     */
    function _position(address user, address token, uint256 withdrawn, uint256 borrowed)
        internal
        view
        returns (Position memory position)
    {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address supportedToken = supportedTokens[i];
            Market storage market = markets[supportedToken];
            if (!market.isActive) continue;

            uint256 depositAmount = userDeposits[user][supportedToken];
            uint256 borrowAmount = userBorrows[user][supportedToken];

            if (supportedToken == token) {
                depositAmount = depositAmount > withdrawn ? depositAmount - withdrawn : 0;
                borrowAmount += borrowed;
            }

            if (depositAmount > 0) {
                uint256 collateralUsd = _valueInUsd(supportedToken, depositAmount, Math.Rounding.Floor);
                position.ltvCollateralUsd += (collateralUsd * market.ltv) / BASIS_POINTS;
                position.thresholdCollateralUsd += (collateralUsd * market.liquidationThreshold) / BASIS_POINTS;
            }

            if (borrowAmount > 0) {
                position.debtUsd += _valueInUsd(supportedToken, borrowAmount, Math.Rounding.Ceil);
            }
        }
    }

    /**
     * @notice Value of `amount` base units of `token` in USD with 8 decimals
     * @dev valueUsd = amount * price / 10^tokenDecimals. The result has 8 decimals whatever the token decimals are,
     *      so values of different tokens can be added and compared.
     * @param token The token address
     * @param amount The amount in base units
     * @param rounding Floor for collateral, Ceil for debt
     * @return The USD value, 8 decimals
     */
    function _valueInUsd(address token, uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(amount, oracle.getAssetPrice(token), 10 ** IERC20Metadata(token).decimals(), rounding);
    }

    /// @dev Reverts unless `ltv <= liquidationThreshold` and `liquidationThreshold * (1 + bonus) <= 100 %`, so that
    ///      the collateral handed out by a liquidation never exceeds the value of the collateral backing the debt.
    function _checkRiskParameters(uint256 ltv, uint256 liquidationThreshold) internal pure {
        // Compare with the highest allowed threshold (9523 = 10000 * 10000 / 10500) instead of multiplying,
        // so that huge inputs revert with the custom error and do not overflow.
        uint256 maxThreshold = (BASIS_POINTS * BASIS_POINTS) / (BASIS_POINTS + LIQUIDATION_BONUS);
        if (ltv > liquidationThreshold || liquidationThreshold > maxThreshold) revert InvalidRiskParameters();
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
     * @notice Cash of a market that is not lent out and can be borrowed or withdrawn right now
     * @param token The token address
     * @return The available liquidity: total supplied minus total borrowed
     */
    function getAvailableLiquidity(address token) public view returns (uint256) {
        return markets[token].totalSupply - markets[token].totalBorrow;
    }

    /**
     * @notice Share of the supplied tokens that is lent out
     * @param token The token address
     * @return Utilization scaled by `WAD` (1e18 = 100%); 0 when nothing is supplied
     */
    function getUtilization(address token) public view returns (uint256) {
        Market storage market = markets[token];
        if (market.totalSupply == 0) return 0;
        return Math.mulDiv(market.totalBorrow, WAD, market.totalSupply);
    }

    /**
     * @notice Annual rate paid by borrowers, a function of the utilization with a kink at `OPTIMAL_UTILIZATION`
     * @dev Below the kink the rate grows from `BASE_BORROW_RATE` by `RATE_SLOPE_1`; above it, `RATE_SLOPE_2` is added
     *      proportionally to how far the utilization is into the remaining range. It rises steeply to attract
     *      repayments and deposits when the market runs out of liquidity.
     * @param token The token address
     * @return The borrow rate, annual and scaled by `WAD`
     */
    function getBorrowRate(address token) public view returns (uint256) {
        uint256 utilization = getUtilization(token);
        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_BORROW_RATE + Math.mulDiv(RATE_SLOPE_1, utilization, OPTIMAL_UTILIZATION);
        }
        return BASE_BORROW_RATE + RATE_SLOPE_1
            + Math.mulDiv(RATE_SLOPE_2, utilization - OPTIMAL_UTILIZATION, WAD - OPTIMAL_UTILIZATION);
    }

    /**
     * @notice Annual rate earned by depositors: what borrowers pay, shared among everything supplied
     * @dev supplyRate = borrowRate * utilization. There is no reserve factor, so depositors earn all the interest.
     * @param token The token address
     * @return The supply rate, annual and scaled by `WAD`
     */
    function getSupplyRate(address token) external view returns (uint256) {
        return Math.mulDiv(getBorrowRate(token), getUtilization(token), WAD);
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
