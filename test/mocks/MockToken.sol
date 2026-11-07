// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title MockToken
 * @notice A simple ERC20 token for testing the lending protocol
 */
contract MockToken is ERC20, Ownable2Step {
    uint8 private _decimals;

    /**
     * @notice Constructor to initialize the token
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals_ The number of decimals
     * @param initialSupply The initial supply of tokens
     */
    constructor(string memory name, string memory symbol, uint8 decimals_, uint256 initialSupply)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _decimals = decimals_;
        _mint(msg.sender, initialSupply);
    }

    /**
     * @notice Mint new tokens (only owner)
     * @param to The address to mint tokens to
     * @param amount The amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from caller
     * @param amount The amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Get the number of decimals
     * @return The number of decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}
