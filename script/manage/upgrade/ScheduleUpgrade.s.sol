// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Schedules the upgrade of the recorded proxy to the recorded next
///         implementation. The timelock accepts the call from a proposer.
///         The proxy owner Safe holds that role.
/// @dev The script writes a `schedule` block into the nextImplementation
///      record after the send. ExecuteUpgrade and CancelUpgrade rebuild their
///      calls from that block, so the operator gives DATA once.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/ScheduleUpgrade.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/ScheduleUpgrade.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract ScheduleUpgrade is UpgradeManage {
    error NextImplementationHasNoCode(address next);
    error AlreadyScheduled(bytes32 operationId);
    error UnknownSelector(bytes4 selector, string contractName);

    function action() public pure override returns (string memory) {
        return "scheduleUpgrade";
    }

    function encode(address next, bytes memory payload) public view returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.schedule,
            (
                proxyAdmin(),
                0,
                upgradeCall(next, payload),
                predecessor(),
                salt(next),
                TimelockController(payable(timelock())).getMinDelay()
            )
        );
    }

    function run() external {
        address next = nextImplementation();
        if (next.code.length == 0) {
            revert NextImplementationHasNoCode(next);
        }
        bytes memory payload = data();
        bytes32 id = operationId(next, payload);
        TimelockController tl = TimelockController(payable(timelock()));

        // A block with `readyAt` names an operation the chain confirmed. A
        // block without it is an unconfirmed intent, and this run replaces it.
        (Schedule memory existing, bool exists) = readSchedule();
        if (exists && existing.hasReadyAt) {
            revert AlreadyScheduled(existing.operationId);
        }
        if (tl.isOperation(id)) {
            revert AlreadyScheduled(id);
        }

        uint256 delay = tl.getMinDelay();
        _send(encode(next, payload));
        _writeSchedule(id, next, payload, delay);

        console2.log("next implementation", next);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("delay (s)", delay);
        console2.log("earliest execute at", block.timestamp + delay);
    }

    function _writeSchedule(bytes32 id, address next, bytes memory payload, uint256 delay) internal {
        string memory key = "schedule";
        vm.serializeBytes32(key, "operationId", id);
        vm.serializeAddress(key, "target", proxyAdmin());
        vm.serializeBytes(key, "calldata", upgradeCall(next, payload));
        vm.serializeBytes(key, "data", payload);
        vm.serializeBytes32(key, "predecessor", predecessor());
        vm.serializeBytes32(key, "salt", salt(next));
        vm.serializeAddress(key, "timelock", timelock());
        vm.serializeUint(key, "delay", delay);
        address safe = safeAddress();
        vm.serializeAddress(key, "proposer", safe == address(0) ? msg.sender : safe);
        string memory out = vm.serializeUint(key, "proposedAt", block.timestamp);
        // Foundry adds the key when it is absent and replaces it when it
        // exists. The rest of the record stays as it is.
        vm.writeJson(out, nextRecordPath(), SCHEDULE_KEY);
    }
}
