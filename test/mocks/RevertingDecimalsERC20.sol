// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A complete ERC20 whose `decimals()` reverts with a named error. The
///      name proves that `initialize` really calls `decimals()` on the asset.
contract RevertingDecimalsERC20 is ERC20 {
    error DecimalsUnavailable();

    constructor() ERC20("Reverting", "REV") {}

    function decimals() public pure override returns (uint8) {
        revert DecimalsUnavailable();
    }
}
