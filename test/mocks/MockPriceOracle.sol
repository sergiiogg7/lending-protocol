// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Settable price source for tests and local deployments. Anyone can set prices: never use it on a real network.
 */
contract MockPriceOracle is IPriceOracle {
    /// @notice No price has been set for the token.
    error PriceNotSet(address token);

    mapping(address => uint256) private _prices;

    /// @notice Sets the USD price (8 decimals) of one whole `token`.
    function setPrice(address token, uint256 price) external {
        _prices[token] = price;
    }

    /// @inheritdoc IPriceOracle
    function getAssetPrice(address token) external view returns (uint256 price) {
        price = _prices[token];
        if (price == 0) revert PriceNotSet(token);
    }
}
