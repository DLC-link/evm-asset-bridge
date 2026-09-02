// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// Forces ETH into a target via selfdestruct, bypassing receive()/fallback().
contract ForceSend {
    constructor() payable {}

    function boom(address payable target) external {
        selfdestruct(target);
    }
}
