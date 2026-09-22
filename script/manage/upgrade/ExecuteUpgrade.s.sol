// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Executes a scheduled upgrade after the delay has passed. The
///         timelock accepts the call from an executor. The proxy owner Safe
///         holds that role.
/// @dev The script rebuilds the call from the `schedule` block that
///      ScheduleUpgrade wrote, and it asks the timelock for the live state
///      first. `OperationNotReady` names the seconds left. `OperationNotOnChain`
///      means the schedule never landed; check the Safe proposal.
///      `OperationDone` means the upgrade already ran; run `make upgrade-sync`.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/ExecuteUpgrade.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/ExecuteUpgrade.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract ExecuteUpgrade is UpgradeManage {
    function action() public pure override returns (string memory) {
        return "executeUpgrade";
    }

    function encode(Schedule memory s) public pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.execute, (s.target, 0, s.callData, s.predecessor, s.salt));
    }

    function run() external {
        (Schedule memory s, bool exists) = readSchedule();
        if (!exists) {
            revert NotScheduled(nextRecordPath());
        }
        _requireLive(s, true);
        _send(encode(s));
        console2.log("executed operation");
        console2.logBytes32(s.operationId);
    }
}
