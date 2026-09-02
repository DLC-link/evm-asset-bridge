// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// Rejects any ETH sent to it. Used to prove a failed withdraw send leaves
/// the request retriable rather than being consumed.
contract RejectingReceiver {
    receive() external payable {
        revert();
    }
}
