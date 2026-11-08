// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IPriceOracle
 * @notice Minimal price source for the lending protocol, modelled on Aave's `IPriceOracleGetter`.
 * @dev Prices are quoted in USD with 8 decimals (Chainlink convention) per ONE WHOLE token, i.e. per
 *      `10 ** decimals()` base units. Implementations must revert instead of returning 0.
 */
interface IPriceOracle {
    /**
     * @notice Returns the USD price of one whole `token`, with 8 decimals.
     * @param token The ERC20 token address
     * @return price USD price scaled by 1e8; never zero
     */
    function getAssetPrice(address token) external view returns (uint256 price);
}
