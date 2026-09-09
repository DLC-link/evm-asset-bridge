// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBridgeWithdraw {
    function withdraw(bytes calldata, address, uint256, uint256, bytes[] calldata) external;
}

/// Receives ETH and immediately re-enters withdraw with stored arguments.
contract ReentrantReceiver {
    IBridgeWithdraw public bridge;
    bytes public requestId;
    uint256 public amount;
    uint256 public deadline;
    bytes[] public sigs;
    bool public reentered;
    bytes public reentryRevertData;

    function arm(IBridgeWithdraw bridge_, bytes calldata id, uint256 amount_, uint256 deadline_, bytes[] calldata sigs_)
        external
    {
        bridge = bridge_;
        requestId = id;
        amount = amount_;
        deadline = deadline_;
        delete sigs;
        for (uint256 i; i < sigs_.length; ++i) {
            sigs.push(sigs_[i]);
        }
    }

    receive() external payable {
        reentered = true;
        try bridge.withdraw(requestId, address(this), amount, deadline, sigs) {
        // must never succeed
        }
        catch (bytes memory data) {
            reentryRevertData = data;
        }
    }
}
