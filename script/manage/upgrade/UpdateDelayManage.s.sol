// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TimelockManage} from "./TimelockManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title UpdateDelayManage
/// @notice The shared half of the three delay scripts. Each one asks the
///         timelock to change its own minimum delay.
/// @dev Schedule, execute and cancel must name one operation. Every argument
///      of that operation therefore comes from this one place. This base
///      reads only the role `timelock`, and it writes no record.
///
///      Change one delay at a time. The salt holds the live delay as the
///      start of the change. Execute and cancel read the live delay again.
///      That value matches the schedule only while no other delay change
///      runs in between. Two changes from the same delay can both be
///      pending. When one of them runs, the scripts cannot derive the other
///      one. They then stop with `OperationNotOnChain`. Cancel a pending
///      change before you schedule another one.
///
///      A change from one delay to another runs once for each timelock. The
///      sequence A to B, B to A, A to B meets a done operation at the third
///      step. A cancelled operation does not count.
abstract contract UpdateDelayManage is TimelockManage {
    /// The same value as `BridgeDeploy.MIN_TIMELOCK_DELAY`. The delay below
    /// it gives no time to react.
    uint256 public constant MIN_DELAY = 60;

    /// An extra zero in DELAY sets a very long delay. Every later upgrade
    /// then waits that long. A change back waits that long too, because
    /// `updateDelay` runs through the timelock. The schedule therefore
    /// refuses a delay above this value.
    uint256 public constant MAX_DELAY = 7 days;

    error DelayTooShort(uint256 newDelay, uint256 minimum);
    error DelayTooLong(uint256 newDelay, uint256 maximum);
    error DelayUnchanged(uint256 delay);

    /// The live minimum delay of the timelock.
    function currentDelay() public view returns (uint256) {
        return TimelockController(payable(timelock())).getMinDelay();
    }

    function updateDelayCall(uint256 newDelay) public pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.updateDelay, (newDelay));
    }

    /// The salt binds the operation to one deployment and one change of
    /// delay. Two deployments that share a timelock address keep their
    /// operation ids apart.
    function delaySalt(uint256 newDelay) public view returns (bytes32) {
        return keccak256(abi.encodePacked(deploymentName(), "-delay-", currentDelay(), newDelay));
    }

    function delayOperationId(uint256 newDelay) public view returns (bytes32) {
        return TimelockController(payable(timelock()))
            .hashOperation(timelock(), 0, updateDelayCall(newDelay), predecessor(), delaySalt(newDelay));
    }
}
