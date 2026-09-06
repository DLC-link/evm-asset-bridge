// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev A token that implements no `decimals()` function. `decimals()` is an
///      OPTIONAL function in EIP-20, so such a token is legal but unbridgeable.
contract NoDecimalsToken {
    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}
