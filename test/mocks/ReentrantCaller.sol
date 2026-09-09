// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// Receives ETH and reenters a stored target with stored calldata. The hook
/// is one-shot (it disarms before the call) and records the callback's result
/// so a test can assert on the exact inner revert. A generic sibling of
/// ReentrantReceiver, which only reenters `withdraw`.
contract ReentrantCaller {
    address public target;
    bytes public callbackData;
    bool public reentered;
    bool public callbackSucceeded;
    bytes public callbackRevertData;

    function arm(address target_, bytes calldata data) external {
        target = target_;
        callbackData = data;
    }

    receive() external payable {
        address target_ = target;
        if (target_ == address(0)) return;
        // Disarm first: without a guard the reentered function sends ETH here
        // again, and a still-armed hook would recurse without bound.
        target = address(0);
        reentered = true;
        (bool ok, bytes memory ret) = target_.call(callbackData);
        callbackSucceeded = ok;
        callbackRevertData = ret;
    }
}
