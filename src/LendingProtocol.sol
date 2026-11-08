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

/**
 * @title LendingProtocol
 * @notice A DeFi lending and borrowing protocol that allows users to:
 * - Deposit tokens to earn interest
 * - Borrow tokens against their deposited collateral
 * - Manage collateralization ratios and liquidation
 */
contract LendingProtocol is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // Structs
    /// @dev Stored state of a market. Supply and borrow are SCALED: amount / index at the time of the operation.
    ///      Real amounts are scaled * index / RAY, so one index grows the interest of every user at once.
    struct MarketState {
        IERC20 token; // The token being lent/borrowed
        uint256 scaledSupply; // Sum of the scaled deposits of all users
        uint256 scaledBorrow; // Sum of the scaled debts of all users
        uint256 liquidityIndex; // Grows with the supply rate; deposits are worth scaled * liquidityIndex
        uint256 borrowIndex; // Grows with the borrow rate; debts are worth scaled * borrowIndex
        uint256 lastUpdateTimestamp; // When the indexes were last updated
        uint256 ltv; // Max loan-to-value in basis points: how much can be borrowed against this collateral
        uint256 liquidationThreshold; // Basis points of this collateral that count for the health factor
        bool isActive; // Whether this market is active
    }

    /// @notice A market as returned by `getMarket`: real amounts and indexes projected to the current block.
    struct Market {
        IERC20 token;
        uint256 totalSupply; // Everything supplied, interest included
        uint256 totalBorrow; // Everything owed, interest included
        uint256 liquidityIndex;
        uint256 borrowIndex;
        uint256 lastUpdateTimestamp;
        uint256 ltv;
        uint256 liquidationThreshold;
        bool isActive;
    }

    /// @dev A user position valued in USD (8 decimals). Collateral is rounded down and debt rounded up.
    struct Position {
        uint256 ltvCollateralUsd; // sum(collateral * ltv): the most debt the position may hold
        uint256 thresholdCollateralUsd; // sum(collateral * liquidationThreshold): counted by the health factor
        uint256 debtUsd; // sum(debt)
    }

    /// @dev A proposed decrease of the liquidation threshold of a market, waiting for its delay.
    struct PendingThreshold {
        uint256 threshold; // The proposed liquidation threshold
        uint256 executableAt; // Timestamp from which it can be executed; 0 when nothing is pending
    }

    // State variables
    mapping(address => mapping(address => uint256)) internal scaledDeposits; // user => token => scaled amount
    mapping(address => mapping(address => uint256)) internal scaledBorrows; // user => token => scaled amount
    mapping(address => MarketState) internal markets;
    mapping(address => PendingThreshold) internal pendingThresholds; // token => proposed threshold decrease

    /// @notice Price source: USD per whole token, 8 decimals. Immutable on purpose.
    IPriceOracle public immutable oracle;

    address[] public supportedTokens;
    uint256 public constant MAX_MARKETS = 16; // the health checks loop over every market, so the loop is bounded
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% extra collateral for the liquidator, in basis points
    uint256 public constant CLOSE_FACTOR = 5000; // 50%: share of a debt that one liquidation may repay
    uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18; // below this health factor 100% can be repaid
    // Interest rate model (annual rates, 1e18 = 100%): a curve with a kink at the optimal utilization
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18;
    uint256 public constant BASE_BORROW_RATE = 0; // borrow rate at 0% utilization
    uint256 public constant RATE_SLOPE_1 = 0.04e18; // rate added going from 0% to the optimal utilization
    uint256 public constant RATE_SLOPE_2 = 0.75e18; // rate added going from the optimal utilization to 100%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant WAD = 1e18; // scale of the health factor, rates and utilization: 1e18 means 1
    uint256 public constant RAY = 1e27; // scale of the interest indexes: 27 decimals keep rounding errors negligible
    uint256 internal constant WAD_TO_RAY = RAY / WAD; // exactly 1e9
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant THRESHOLD_DECREASE_DELAY = 2 days; // notice before a lower liquidation threshold applies

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
    /// @notice The user has no debt in the token to liquidate.
    error NoDebtToLiquidate();
    /// @notice The health factor of the position is not below 1.
    error NotLiquidatable();
    /// @notice The user does not hold enough of the chosen collateral to pay the liquidation bonus.
    error InsufficientCollateral();
    /// @notice The amount to recover is more than the contract holds beyond what it owes to depositors.
    error AmountExceedsSurplus();
    /// @notice The address is not an ERC20 that the protocol can list (not a contract, no `decimals()`, or more than 18).
    error InvalidToken();
    /// @notice The token delivered less than the amount requested: fee-on-transfer tokens are not supported.
    error UnsupportedToken();
    /// @notice The protocol already lists `MAX_MARKETS` markets.
    error TooManyMarkets();
    /// @notice There is no proposed liquidation threshold decrease for the market.
    error NoPendingChange();
    /// @notice The delay of the proposed liquidation threshold decrease has not passed yet.
    error ChangeNotReady();

    // Events
    /// @notice Emitted when a market is added.
    event MarketAdded(address indexed token, uint256 ltv, uint256 liquidationThreshold);
    /// @notice Emitted when the risk parameters of a market change.
    event MarketUpdated(address indexed token, uint256 ltv, uint256 liquidationThreshold);
    /// @notice Emitted when a decrease of the liquidation threshold is proposed; it can be executed from `executableAt`.
    event LiquidationThresholdDecreaseProposed(address indexed token, uint256 newThreshold, uint256 executableAt);
    /// @notice Emitted when a proposed decrease of the liquidation threshold is cancelled.
    event LiquidationThresholdDecreaseCancelled(address indexed token);
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
        if (supportedTokens.length >= MAX_MARKETS) revert TooManyMarkets();
        _validateToken(token);

        markets[token] = MarketState({
            token: IERC20(token),
            scaledSupply: 0,
            scaledBorrow: 0,
            liquidityIndex: RAY,
            borrowIndex: RAY,
            lastUpdateTimestamp: block.timestamp,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            isActive: true
        });

        supportedTokens.push(token);
        emit MarketAdded(token, ltv, liquidationThreshold);
    }

    /**
     * @notice Change the max loan-to-value of a market. Takes effect immediately.
     * @dev The LTV only limits NEW borrows: it never makes an existing position liquidatable, so it needs no delay.
     *      Setting it to 0 is the emergency lever to stop borrowing against a collateral.
     * @param token The token address
     * @param ltv New max loan-to-value in basis points (<= the liquidation threshold)
     */
    function setLtv(address token, uint256 ltv) external onlyOwner onlyActiveMarket(token) {
        uint256 liquidationThreshold = markets[token].liquidationThreshold;
        _checkRiskParameters(ltv, liquidationThreshold);

        markets[token].ltv = ltv;
        emit MarketUpdated(token, ltv, liquidationThreshold);
    }

    /**
     * @notice Raise the liquidation threshold of a market. Takes effect immediately.
     * @dev A higher threshold only makes positions safer, so it needs no delay.
     * @param token The token address
     * @param liquidationThreshold New liquidation threshold in basis points (>= the current one)
     */
    function raiseLiquidationThreshold(address token, uint256 liquidationThreshold)
        external
        onlyOwner
        onlyActiveMarket(token)
    {
        uint256 ltv = markets[token].ltv;
        if (liquidationThreshold < markets[token].liquidationThreshold) revert InvalidRiskParameters();
        _checkRiskParameters(ltv, liquidationThreshold);

        markets[token].liquidationThreshold = liquidationThreshold;
        emit MarketUpdated(token, ltv, liquidationThreshold);
    }

    /**
     * @notice Propose a lower liquidation threshold. It can be executed after `THRESHOLD_DECREASE_DELAY`.
     * @dev A lower threshold can make existing positions liquidatable, so users get two days of notice to repay or
     *      add collateral. A new proposal replaces the pending one and restarts the delay.
     * @param token The token address
     * @param newThreshold The proposed threshold in basis points (lower than the current one, >= the LTV)
     */
    function proposeLiquidationThresholdDecrease(address token, uint256 newThreshold)
        external
        onlyOwner
        onlyActiveMarket(token)
    {
        if (newThreshold >= markets[token].liquidationThreshold) revert InvalidRiskParameters();
        _checkRiskParameters(markets[token].ltv, newThreshold);

        uint256 executableAt = block.timestamp + THRESHOLD_DECREASE_DELAY;
        pendingThresholds[token] = PendingThreshold({threshold: newThreshold, executableAt: executableAt});
        emit LiquidationThresholdDecreaseProposed(token, newThreshold, executableAt);
    }

    /**
     * @notice Apply the proposed liquidation threshold decrease once its delay has passed
     * @dev The parameters are checked again, since the LTV may have changed since the proposal.
     * @param token The token address
     */
    function executeLiquidationThresholdDecrease(address token) external onlyOwner {
        PendingThreshold memory pending = pendingThresholds[token];
        if (pending.executableAt == 0) revert NoPendingChange();
        if (block.timestamp < pending.executableAt) revert ChangeNotReady();

        uint256 ltv = markets[token].ltv;
        _checkRiskParameters(ltv, pending.threshold);

        delete pendingThresholds[token];
        markets[token].liquidationThreshold = pending.threshold;
        emit MarketUpdated(token, ltv, pending.threshold);
    }

    /**
     * @notice Cancel the proposed liquidation threshold decrease
     * @param token The token address
     */
    function cancelLiquidationThresholdDecrease(address token) external onlyOwner {
        if (pendingThresholds[token].executableAt == 0) revert NoPendingChange();

        delete pendingThresholds[token];
        emit LiquidationThresholdDecreaseCancelled(token);
    }

    /**
     * @notice Deposit tokens to earn interest
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        _deposit(token, amount);
    }

    /**
     * @notice Withdraw deposited tokens
     * @param token The token to withdraw
     * @param amount The amount to withdraw, or `type(uint256).max` for the whole balance including interest
     */
    function withdraw(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();
        _accrue(token);

        uint256 balance = _userDeposit(msg.sender, token);
        if (amount == type(uint256).max) amount = balance;
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert ZeroAmount();
        if (balance < amount) revert InsufficientDeposit();
        if (getAvailableLiquidity(token) < amount) revert InsufficientLiquidity();
        if (!canWithdraw(msg.sender, token, amount)) revert WithdrawalUnsafe();

        _burnDeposit(msg.sender, token, amount);

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
        _accrue(token);
        if (getAvailableLiquidity(token) < amount) revert InsufficientLiquidity();
        if (!canBorrow(msg.sender, token, amount)) revert BorrowExceedsCollateral();

        // The debt is rounded up: the borrower never owes less than was lent
        uint256 scaled = Math.mulDiv(amount, RAY, markets[token].borrowIndex, Math.Rounding.Ceil);
        scaledBorrows[msg.sender][token] += scaled;
        markets[token].scaledBorrow += scaled;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }

    /**
     * @notice Repay borrowed tokens
     * @param token The token to repay
     * @param amount The amount to repay, or `type(uint256).max` for the whole debt including interest
     */
    function repay(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) {
        if (amount == 0) revert ZeroAmount();
        _accrue(token);

        uint256 debt = _userBorrow(msg.sender, token);
        if (amount == type(uint256).max) amount = debt;
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert ZeroAmount();
        if (debt < amount) revert InsufficientBorrow();

        _burnDebt(msg.sender, token, amount);

        // Interaction last (Checks-Effects-Interactions)
        _pull(token, amount);

        emit Repay(msg.sender, token, amount);
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
        _accrue(debtToken);
        _accrue(collateralToken);

        uint256 healthFactor = getHealthFactor(user);
        if (healthFactor >= WAD) revert NotLiquidatable();

        uint256 userDebt = _userBorrow(user, debtToken);
        // slither-disable-next-line incorrect-equality
        if (userDebt == 0) revert NoDebtToLiquidate();

        // Close factor: half of the debt (rounded up, so tiny debts can be cleared), or all of it when deep underwater
        uint256 maxDebtToCover = healthFactor < CLOSE_FACTOR_HF_THRESHOLD
            ? userDebt
            : Math.mulDiv(userDebt, CLOSE_FACTOR, BASIS_POINTS, Math.Rounding.Ceil);
        if (debtToCover > maxDebtToCover) debtToCover = maxDebtToCover;

        uint256 collateralSeized = _collateralToSeize(collateralToken, debtToken, debtToCover);
        if (_userDeposit(user, collateralToken) < collateralSeized) revert InsufficientCollateral();

        // The contract must hold the collateral that is not lent out
        if (getAvailableLiquidity(collateralToken) < collateralSeized) revert InsufficientLiquidity();

        _burnDebt(user, debtToken, debtToCover);
        _burnDeposit(user, collateralToken, collateralSeized);

        // Interactions last: take the debt tokens from the liquidator, then pay the seized collateral
        _pull(debtToken, debtToCover);
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
        uint256 marketCount = supportedTokens.length;
        for (uint256 i = 0; i < marketCount; i++) {
            address supportedToken = supportedTokens[i];
            MarketState storage market = markets[supportedToken];
            if (!market.isActive) continue;

            uint256 depositAmount = _userDeposit(user, supportedToken);
            uint256 borrowAmount = _userBorrow(user, supportedToken);

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
        // The position loops over the markets and values each asset: one oracle call per market, bounded by MAX_MARKETS
        // slither-disable-next-line calls-loop
        return Math.mulDiv(amount, oracle.getAssetPrice(token), 10 ** IERC20Metadata(token).decimals(), rounding);
    }

    /// @dev Pulls `amount` of `token` from the caller and checks that exactly that amount arrived. Tokens that charge a
    ///      fee on transfer would leave the protocol owing more than it holds, so they are rejected here.
    function _pull(address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        // slither-disable-next-line incorrect-equality
        if (IERC20(token).balanceOf(address(this)) - balanceBefore != amount) revert UnsupportedToken();
    }

    /// @dev A listable token is a contract with `decimals()` up to 18 and a price in the oracle. A market whose price
    ///      is missing would make every position holding it impossible to value.
    function _validateToken(address token) internal view {
        if (token.code.length == 0) revert InvalidToken();
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            if (tokenDecimals > 18) revert InvalidToken();
        } catch {
            revert InvalidToken();
        }
        // slither-disable-next-line incorrect-equality
        if (oracle.getAssetPrice(token) == 0) revert InvalidToken();
    }

    /// @dev Credits `amount` to the caller, as scaled shares, and pulls the tokens.
    function _deposit(address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _accrue(token);

        // Rounded down: the depositor never gets a claim larger than what was handed over
        uint256 scaled = Math.mulDiv(amount, RAY, markets[token].liquidityIndex);
        // slither-disable-next-line incorrect-equality
        if (scaled == 0) revert ZeroAmount();
        scaledDeposits[msg.sender][token] += scaled;
        markets[token].scaledSupply += scaled;

        // Interaction last (Checks-Effects-Interactions)
        _pull(token, amount);

        emit Deposit(msg.sender, token, amount);
    }

    /// @dev Removes `amount` (real units) from a user deposit; the scaled amount is rounded up.
    function _burnDeposit(address user, address token, uint256 amount) internal {
        uint256 userScaled = scaledDeposits[user][token];
        uint256 scaled = Math.mulDiv(amount, RAY, markets[token].liquidityIndex, Math.Rounding.Ceil);
        if (scaled > userScaled) scaled = userScaled;
        scaledDeposits[user][token] = userScaled - scaled;
        markets[token].scaledSupply -= scaled;
    }

    /// @dev Removes `amount` (real units) from a user debt; the scaled amount is rounded down, so a repayment never
    ///      erases more debt than was paid.
    function _burnDebt(address user, address token, uint256 amount) internal {
        uint256 userScaled = scaledBorrows[user][token];
        uint256 scaled = Math.mulDiv(amount, RAY, markets[token].borrowIndex);
        if (scaled > userScaled) scaled = userScaled;
        // slither-disable-next-line incorrect-equality
        if (scaled == 0) revert ZeroAmount();
        scaledBorrows[user][token] = userScaled - scaled;
        markets[token].scaledBorrow -= scaled;
    }

    /// @dev Brings the indexes of a market up to the current block, before its balances change.
    function _accrue(address token) internal {
        MarketState storage market = markets[token];
        // slither-disable-next-line incorrect-equality
        if (market.lastUpdateTimestamp == block.timestamp) return;
        (market.liquidityIndex, market.borrowIndex) = _indexes(market);
        market.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @dev The indexes of a market projected to the current block, without writing them.
     *      newIndex = index * (1 + rate * elapsed / year), with the rates of the last update (they only change when
     *      someone interacts with the market). The borrow index is rounded up and the liquidity index down.
     *      Everything is computed in RAY: the supply rate is borrowRate * borrowed / supplied, so what depositors earn
     *      matches what borrowers pay up to a rounding error of 1e-27.
     */
    function _indexes(MarketState storage market) internal view returns (uint256 liquidityIndex, uint256 borrowIndex) {
        liquidityIndex = market.liquidityIndex;
        borrowIndex = market.borrowIndex;
        uint256 elapsed = block.timestamp - market.lastUpdateTimestamp;
        // slither-disable-next-line incorrect-equality
        if (elapsed == 0) return (liquidityIndex, borrowIndex);

        (uint256 supplied, uint256 borrowed) = _storedTotals(market);
        uint256 borrowRate = _borrowRate(_utilization(market)) * WAD_TO_RAY;
        uint256 supplyRate =
            supplied == 0 ? 0 : Math.mulDiv(borrowRate, borrowed > supplied ? supplied : borrowed, supplied);

        borrowIndex =
            Math.mulDiv(borrowIndex, RAY + Math.mulDiv(borrowRate, elapsed, SECONDS_PER_YEAR), RAY, Math.Rounding.Ceil);
        liquidityIndex = Math.mulDiv(liquidityIndex, RAY + Math.mulDiv(supplyRate, elapsed, SECONDS_PER_YEAR), RAY);
    }

    /// @dev Total supplied (rounded down) and borrowed (rounded up) with the stored indexes, as of the last update.
    function _storedTotals(MarketState storage market) internal view returns (uint256 supplied, uint256 borrowed) {
        supplied = Math.mulDiv(market.scaledSupply, market.liquidityIndex, RAY);
        borrowed = Math.mulDiv(market.scaledBorrow, market.borrowIndex, RAY, Math.Rounding.Ceil);
    }

    /// @dev Utilization from the stored indexes, capped at 100 %: rounding can leave the debt a wei above the supply.
    function _utilization(MarketState storage market) internal view returns (uint256) {
        (uint256 supplied, uint256 borrowed) = _storedTotals(market);
        if (supplied == 0) return 0;
        return borrowed >= supplied ? WAD : Math.mulDiv(borrowed, WAD, supplied);
    }

    /// @dev The kinked rate curve; see `getBorrowRate`.
    function _borrowRate(uint256 utilization) internal pure returns (uint256) {
        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_BORROW_RATE + Math.mulDiv(RATE_SLOPE_1, utilization, OPTIMAL_UTILIZATION);
        }
        return BASE_BORROW_RATE + RATE_SLOPE_1
            + Math.mulDiv(RATE_SLOPE_2, utilization - OPTIMAL_UTILIZATION, WAD - OPTIMAL_UTILIZATION);
    }

    /// @dev Real deposit of a user (interest included, rounded down) as of the current block.
    function _userDeposit(address user, address token) internal view returns (uint256) {
        (uint256 liquidityIndex,) = _indexes(markets[token]);
        return Math.mulDiv(scaledDeposits[user][token], liquidityIndex, RAY);
    }

    /// @dev Real debt of a user (interest included, rounded up) as of the current block.
    function _userBorrow(address user, address token) internal view returns (uint256) {
        (, uint256 borrowIndex) = _indexes(markets[token]);
        return Math.mulDiv(scaledBorrows[user][token], borrowIndex, RAY, Math.Rounding.Ceil);
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
     * @notice Get market information, with real amounts and indexes projected to the current block
     * @param token The token address
     * @return Market information
     */
    function getMarket(address token) external view returns (Market memory) {
        MarketState storage market = markets[token];
        (uint256 liquidityIndex, uint256 borrowIndex) = _indexes(market);
        return Market({
            token: market.token,
            totalSupply: Math.mulDiv(market.scaledSupply, liquidityIndex, RAY),
            totalBorrow: Math.mulDiv(market.scaledBorrow, borrowIndex, RAY, Math.Rounding.Ceil),
            liquidityIndex: liquidityIndex,
            borrowIndex: borrowIndex,
            lastUpdateTimestamp: market.lastUpdateTimestamp,
            ltv: market.ltv,
            liquidationThreshold: market.liquidationThreshold,
            isActive: market.isActive
        });
    }

    /**
     * @notice Cash of a market that is not lent out and can be borrowed or withdrawn right now
     * @dev Supplied minus borrowed, interest included on both sides, as of the current block.
     * @param token The token address
     * @return The available liquidity
     */
    function getAvailableLiquidity(address token) public view returns (uint256) {
        MarketState storage market = markets[token];
        (uint256 liquidityIndex, uint256 borrowIndex) = _indexes(market);
        uint256 supplied = Math.mulDiv(market.scaledSupply, liquidityIndex, RAY);
        uint256 borrowed = Math.mulDiv(market.scaledBorrow, borrowIndex, RAY, Math.Rounding.Ceil);
        return supplied > borrowed ? supplied - borrowed : 0;
    }

    /**
     * @notice Share of the supplied tokens that is lent out, as of the last update of the market
     * @param token The token address
     * @return Utilization scaled by `WAD` (1e18 = 100%); 0 when nothing is supplied
     */
    function getUtilization(address token) public view returns (uint256) {
        return _utilization(markets[token]);
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
        return _borrowRate(getUtilization(token));
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
     * @notice Get user's deposit for a specific token, interest included
     * @param user The user address
     * @param token The token address
     * @return The deposit amount as of the current block
     */
    function getUserDeposit(address user, address token) external view returns (uint256) {
        return _userDeposit(user, token);
    }

    /**
     * @notice Get user's debt for a specific token, interest included
     * @param user The user address
     * @param token The token address
     * @return The debt as of the current block
     */
    function getUserBorrow(address user, address token) external view returns (uint256) {
        return _userBorrow(user, token);
    }

    /**
     * @notice The proposed liquidation threshold decrease of a market, if any
     * @param token The token address
     * @return threshold The proposed threshold (0 when nothing is pending)
     * @return executableAt When it can be executed (0 when nothing is pending)
     */
    function getPendingLiquidationThreshold(address token)
        external
        view
        returns (uint256 threshold, uint256 executableAt)
    {
        PendingThreshold memory pending = pendingThresholds[token];
        return (pending.threshold, pending.executableAt);
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
     * @notice Amount of `token` the owner may recover: what the contract holds beyond the cash backing deposits
     * @dev The cash that backs deposits is the available liquidity (supplied minus borrowed); interest that is owed
     *      but not yet paid is not held, so it creates no surplus. For a token without a market the available
     *      liquidity is 0 and everything held is recoverable. Typical surplus: tokens sent by mistake, donations and
     *      rounding dust.
     * @param token The token address
     * @return The recoverable amount
     */
    function getRecoverableAmount(address token) public view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 owedToDepositors = getAvailableLiquidity(token);
        return balance > owedToDepositors ? balance - owedToDepositors : 0;
    }

    /**
     * @notice Recover tokens that do not belong to depositors: sent by mistake, donated, or rounding dust
     * @dev Never touches user funds: `amount` cannot exceed `getRecoverableAmount(token)`.
     * @param token The token to recover
     * @param to The address to send tokens to
     * @param amount The amount to recover
     */
    function emergencyRecover(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount > getRecoverableAmount(token)) revert AmountExceedsSurplus();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovered(token, to, amount);
    }
}
