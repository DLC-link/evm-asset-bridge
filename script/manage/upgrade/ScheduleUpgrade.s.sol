// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Schedules the upgrade of the recorded proxy to the recorded next
///         implementation. The timelock accepts the call from a proposer.
///         The proxy owner Safe holds that role.
/// @dev The script writes a `schedule` block into the nextImplementation
///      record after the send. ExecuteUpgrade and CancelUpgrade rebuild their
///      calls from that block, so the operator gives DATA once.
///      Before the send, the script runs the whole `upgradeAndCall` as the
///      timelock against a state snapshot. A payload that reverts stops the
///      run here, before anyone signs. The simulation proves nothing about
///      the payload's effect. A reinitializer that resets `totalLocked` on a
///      funded bridge passes it. The payload reviewer owns that check; see
///      script/manage/README.md.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/ScheduleUpgrade.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/ScheduleUpgrade.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract ScheduleUpgrade is UpgradeManage {
    error NextImplementationHasNoCode(address next);
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

        if (payload.length > 0) {
            _requireKnownSelector(payload);
        }
        _simulateUpgrade(next, payload);

        uint256 delay = tl.getMinDelay();
        _send(encode(next, payload));
        _writeSchedule(id, next, payload, delay);

        console2.log("next implementation", next);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("delay (s)", delay);
        console2.log("earliest execute at", block.timestamp + delay);
    }

    /// The first four bytes of the payload must name a function of the next
    /// implementation. The artifact's `methodIdentifiers` lists every
    /// external function signature, and the record names the artifact. A
    /// stale `out/` compares against an old ABI; `_simulateUpgrade` runs the
    /// payload against the live bytecode and is the authoritative gate.
    function _requireKnownSelector(bytes memory payload) internal view {
        string memory record = vm.readFile(nextRecordPath());
        string memory name = vm.parseJsonString(record, ".contractName");
        string memory source = vm.parseJsonString(record, ".sourcePath");
        string memory artifact = vm.readFile(vm.getArtifactPathByCode(vm.getCode(string.concat(source, ":", name))));
        string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        bytes4 selector = bytes4(payload);
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == selector) {
                return;
            }
        }
        revert UnknownSelector(selector, name);
    }

    /// Runs the upgrade as the timelock, then restores the state. A revert
    /// bubbles with the payload's own error.
    function _simulateUpgrade(address next, bytes memory payload) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(timelock());
        ProxyAdmin(proxyAdmin()).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy())), next, payload);
        // A schedule simulated against an already upgraded proxy would hide a
        // real problem, so the restore must succeed.
        require(vm.revertToState(snapshot), "state snapshot did not restore");
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
