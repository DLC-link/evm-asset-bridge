// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpdateDelayManage} from "./UpdateDelayManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Schedules a change of the timelock's minimum delay. The timelock
///         accepts the call from a proposer. The proxy owner Safe holds that
///         role.
/// @dev The script checks the floor, the ceiling, the change and the operation state
///      before the send. Change one delay at a time; see UpdateDelayManage.
///      The script writes no record. Execute and cancel derive the operation
///      again from the same new delay.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/ScheduleUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/ScheduleUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL
contract ScheduleUpdateDelay is UpdateDelayManage {
    function action() public pure override returns (string memory) {
        return "scheduleUpdateDelay";
    }

    function encode(uint256 newDelay) public view returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.schedule,
            (timelock(), 0, updateDelayCall(newDelay), predecessor(), delaySalt(newDelay), currentDelay())
        );
    }

    function run(uint256 newDelay) external {
        if (newDelay < MIN_DELAY) {
            revert DelayTooShort(newDelay, MIN_DELAY);
        }
        if (newDelay > MAX_DELAY) {
            revert DelayTooLong(newDelay, MAX_DELAY);
        }
        uint256 delay = currentDelay();
        if (newDelay == delay) {
            revert DelayUnchanged(delay);
        }

        TimelockController tl = TimelockController(payable(timelock()));
        bytes32 id = delayOperationId(newDelay);
        TimelockController.OperationState state = tl.getOperationState(id);
        if (state == TimelockController.OperationState.Done) {
            revert OperationDone(id);
        }
        if (state != TimelockController.OperationState.Unset) {
            revert AlreadyScheduled(id);
        }

        // A decrease shortens the review window of every later upgrade.
        // The script prints one line for it and does not stop.
        if (newDelay < delay) {
            console2.log("DECREASE: current delay (s)", delay, "-> new delay (s)", newDelay);
        }

        _send(encode(newDelay));

        console2.log("timelock", address(tl));
        console2.log("current delay (s)", delay);
        console2.log("new delay (s)", newDelay);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("earliest execute at", block.timestamp + delay);
    }
}
