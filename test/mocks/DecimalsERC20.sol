// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev An ERC20 whose `decimals()` the test chooses.
contract DecimalsERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Decimals", "DEC") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
