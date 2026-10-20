// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TimelockManage} from "./TimelockManage.s.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title UpgradeManage
/// @notice The shared half of the three upgrade scripts. Each one calls the
///         timelock that owns the ProxyAdmin, never the ProxyAdmin itself.
///         The timelock handling lives in TimelockManage.
/// @dev Schedule, execute and cancel must name one operation. Every argument
///      of that operation therefore comes from this one place. The scripts
///      hold no knowledge of the contract behind the proxy. They read the
///      roles `proxy`, `proxyAdmin`, `timelock` and `nextImplementation`
///      from the deployment records, and nothing else.
abstract contract UpgradeManage is TimelockManage {
    /// The part of the `schedule` block that execute and cancel need. The
    /// block lives in the nextImplementation record. ScheduleUpgrade writes
    /// it, and `script/upgrade-sync.sh` adds `readyAt` once the chain knows
    /// the operation.
    struct Schedule {
        bytes32 operationId;
        address target;
        bytes callData;
        bytes32 predecessor;
        bytes32 salt;
        bool hasReadyAt;
        uint256 readyAt;
    }

    error NotScheduled(string recordPath);
    error ScheduleMismatch(bytes32 recordedId, bytes32 derivedId);

    string internal constant SCHEDULE_KEY = ".schedule";

    function proxyAdmin() public view returns (address) {
        return recordAddress("proxyAdmin");
    }

    function proxy() public view returns (address) {
        return recordAddress("proxy");
    }

    function nextImplementation() public view returns (address) {
        return recordAddress("nextImplementation");
    }

    /// The optional payload for `upgradeAndCall`. The operator sets DATA in
    /// the environment. Unset, empty and `0x` all mean no payload. A test
    /// overrides this function instead of the environment.
    function data() public view virtual returns (bytes memory) {
        string memory raw = vm.envOr("DATA", string(""));
        if (bytes(raw).length == 0 || keccak256(bytes(raw)) == keccak256(bytes("0x"))) {
            return "";
        }
        return vm.parseBytes(raw);
    }

    function nextRecordPath() public view returns (string memory) {
        return
            string.concat("deployments/", deploymentName(), ".nextImplementation.", vm.toString(block.chainid), ".json");
    }

    /// The call that the timelock forwards to the ProxyAdmin.
    function upgradeCall(address next, bytes memory payload) public view returns (bytes memory) {
        return
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(payable(proxy())), next, payload));
    }

    /// The salt binds the operation to one deployment and one implementation.
    /// Two deployments on one chain can share a timelock in the future. The
    /// salt then keeps their operation ids apart.
    function salt(address next) public view returns (bytes32) {
        return keccak256(abi.encodePacked(deploymentName(), "-upgrade-", next));
    }

    /// The id that the timelock stores for this upgrade.
    function operationId(address next, bytes memory payload) public view returns (bytes32) {
        return TimelockController(payable(timelock()))
            .hashOperation(proxyAdmin(), 0, upgradeCall(next, payload), predecessor(), salt(next));
    }

    /// Reads the schedule block. `exists` is false when the record or the
    /// block is missing.
    function readSchedule() public view returns (Schedule memory s, bool exists) {
        string memory path = nextRecordPath();
        if (!vm.exists(path)) {
            return (s, false);
        }
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, SCHEDULE_KEY)) {
            return (s, false);
        }
        s.operationId = vm.parseJsonBytes32(json, string.concat(SCHEDULE_KEY, ".operationId"));
        s.target = vm.parseJsonAddress(json, string.concat(SCHEDULE_KEY, ".target"));
        s.callData = vm.parseJsonBytes(json, string.concat(SCHEDULE_KEY, ".calldata"));
        s.predecessor = vm.parseJsonBytes32(json, string.concat(SCHEDULE_KEY, ".predecessor"));
        s.salt = vm.parseJsonBytes32(json, string.concat(SCHEDULE_KEY, ".salt"));
        s.hasReadyAt = vm.keyExistsJson(json, string.concat(SCHEDULE_KEY, ".readyAt"));
        if (s.hasReadyAt) {
            s.readyAt = vm.parseJsonUint(json, string.concat(SCHEDULE_KEY, ".readyAt"));
        }
        // A block edited by hand can name one operation and describe another.
        // Execute and cancel act on both, so the two must agree.
        bytes32 derived =
            TimelockController(payable(timelock())).hashOperation(s.target, 0, s.callData, s.predecessor, s.salt);
        if (s.operationId != derived) {
            revert ScheduleMismatch(s.operationId, derived);
        }
        return (s, true);
    }
}
