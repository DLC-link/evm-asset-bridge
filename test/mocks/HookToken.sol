// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC777-style token: `transfer` and `transferFrom` run a callback into a
/// stored target after the balance change, as a transfer hook would. The hook
/// is one-shot (it disarms before the call) and records the callback's result
/// so a test can assert on the exact inner revert.
contract HookToken is ERC20 {
    address public target;
    bytes public callbackData;
    bool public callbackRan;
    bool public callbackSucceeded;
    bytes public callbackRevertData;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata data) external {
        target = target_;
        callbackData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool ok) {
        ok = super.transfer(to, value);
        _callback();
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        ok = super.transferFrom(from, to, value);
        _callback();
    }

    function _callback() internal {
        address target_ = target;
        if (target_ == address(0)) return;
        // Disarm first: without a guard the reentered function transfers
        // again, and a still-armed hook would recurse without bound.
        target = address(0);
        callbackRan = true;
        (bool ok, bytes memory ret) = target_.call(callbackData);
        callbackSucceeded = ok;
        callbackRevertData = ret;
    }
}
