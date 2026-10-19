// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ManageBase} from "../ManageBase.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TimelockManage
/// @notice The base of every script that drives the timelock. Each such script
///         calls the timelock, never the contract that the timelock owns.
/// @dev The bridge's `defaultAdminDelay` is a different mechanism. It lives in
///      the bridge and stays outside this base. This base reads only the role
///      `timelock`.
abstract contract TimelockManage is ManageBase {
    error OperationNotOnChain(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint256 readyAt, uint256 secondsLeft);
    error OperationDone(bytes32 operationId);
    error AlreadyScheduled(bytes32 operationId);

    /// The record defines the contract. The folder guard therefore skips
    /// its name comparison.
    function acceptsAnyContract() public pure override returns (bool) {
        return true;
    }

    function contractName() public pure override returns (string memory) {
        return "";
    }

    function timelock() public view returns (address) {
        return recordAddress("timelock");
    }

    /// Every timelock action calls the timelock. The timelock then calls its
    /// own target, after the delay.
    function target() internal view override returns (address) {
        return timelock();
    }

    /// No operation depends on an earlier operation.
    function predecessor() public pure returns (bytes32) {
        return bytes32(0);
    }

    /// Reads the live state of an operation. It rejects `Unset` and `Done`
    /// always, and `Waiting` when the caller needs `Ready`. The errors tell
    /// the operator what to do next.
    function _requireLive(bytes32 id, bool needReady) internal view {
        TimelockController tl = TimelockController(payable(timelock()));
        TimelockController.OperationState state = tl.getOperationState(id);
        if (state == TimelockController.OperationState.Unset) {
            revert OperationNotOnChain(id);
        }
        if (state == TimelockController.OperationState.Done) {
            revert OperationDone(id);
        }
        if (needReady && state == TimelockController.OperationState.Waiting) {
            uint256 readyAt = tl.getTimestamp(id);
            revert OperationNotReady(id, readyAt, readyAt - block.timestamp);
        }
    }
}
