// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeToken
 * @notice An ERC20 that burns a fee on every transfer, so the receiver gets less than what was sent.
 *         Anyone can mint and change the fee: for tests only.
 */
contract MockFeeToken is ERC20 {
    uint256 public feeBps;

    constructor(string memory name, string memory symbol, uint256 feeBps_) ERC20(name, symbol) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
