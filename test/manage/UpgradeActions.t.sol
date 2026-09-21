// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {UpgradeManage} from "../../script/manage/upgrade/UpgradeManage.s.sol";
import {ScheduleUpgrade} from "../../script/manage/upgrade/ScheduleUpgrade.s.sol";
import {CounterV1, CounterV2} from "../mocks/CounterUpgradeable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// Each double fixes the three values that come from the environment in a
/// real run. Everything else comes from the record files the test writes,
/// so the tests cover the record reads too.
contract DummySchedule is ScheduleUpgrade {
    string private _name;
    address private _safe;
    bytes private _payload;

    function configure(string memory name, address safe_, bytes memory payload) external {
        _name = name;
        _safe = safe_;
        _payload = payload;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }

    function data() public view override returns (bytes memory) {
        return _payload;
    }
}

/// The fixture: a counter behind a transparent proxy whose ProxyAdmin
/// belongs to a timelock. The Safe is the proposer, canceller and executor.
abstract contract UpgradeFixture is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    uint256 internal constant DELAY = 1 hours;

    address internal safe = makeAddr("safe");
    address internal outsider = makeAddr("outsider");

    TimelockController internal timelock;
    address internal proxy;
    address internal proxyAdmin;
    address internal oldImpl;
    address internal nextImpl;
    string internal nextContractName;
    string internal nextSourcePath;

    function _deployTimelock() internal returns (TimelockController) {
        address[] memory holders = new address[](1);
        holders[0] = safe;
        return new TimelockController(DELAY, holders, holders, address(0));
    }

    function _path(string memory name, string memory role) internal pure returns (string memory) {
        return string.concat("deployments/", name, ".", role, ".31337.json");
    }

    function _envelope(string memory name, string memory action) internal pure returns (string memory) {
        return string.concat("deployments/.safe/", name, ".31337.", action, ".json");
    }

    function _writeRecord(string memory name, string memory role, address addr) internal {
        string memory key = string.concat(name, role);
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", nextContractName);
        vm.serializeString(key, "sourcePath", nextSourcePath);
        vm.writeJson(vm.serializeAddress(key, "address", addr), _path(name, role));
    }

    /// The four records the upgrade scripts read. The implementation record
    /// is absent on purpose: a generic script must not need it.
    function _writeRecords(string memory name) internal {
        _writeRecord(name, "timelock", address(timelock));
        _writeRecord(name, "proxyAdmin", proxyAdmin);
        _writeRecord(name, "proxy", proxy);
        _writeRecord(name, "nextImplementation", nextImpl);
    }

    function _removeRecords(string memory name) internal {
        vm.removeFile(_path(name, "timelock"));
        vm.removeFile(_path(name, "proxyAdmin"));
        vm.removeFile(_path(name, "proxy"));
        vm.removeFile(_path(name, "nextImplementation"));
        string[3] memory actions = ["scheduleUpgrade", "executeUpgrade", "cancelUpgrade"];
        for (uint256 i; i < actions.length; ++i) {
            string memory envelope = _envelope(name, actions[i]);
            if (vm.exists(envelope)) {
                vm.removeFile(envelope);
            }
        }
    }

    function _schedule(string memory name, bytes memory payload) internal returns (DummySchedule s) {
        s = new DummySchedule();
        s.configure(name, safe, payload);
        s.run();
    }

    function _implementationOf(address p) internal view returns (address) {
        return address(uint160(uint256(vm.load(p, IMPLEMENTATION_SLOT))));
    }
}

contract UpgradeActionsTest is UpgradeFixture {
    function setUp() public {
        timelock = _deployTimelock();
        oldImpl = address(new CounterV1());
        proxy = address(
            new TransparentUpgradeableProxy(oldImpl, address(timelock), abi.encodeCall(CounterV1.initialize, (5)))
        );
        proxyAdmin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        nextImpl = address(new CounterV2());
        nextContractName = "CounterV2";
        nextSourcePath = "test/mocks/CounterUpgradeable.sol";
    }

    function test_schedule_revertsForANonProposer() public {
        string memory name = "UPGNOPROP";
        _writeRecords(name);
        DummySchedule s = new DummySchedule();
        s.configure(name, outsider, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, timelock.PROPOSER_ROLE()
            )
        );
        s.run();

        assertFalse(vm.exists(_envelope(name, "scheduleUpgrade")));
        _removeRecords(name);
    }

    function test_schedule_fromTheSafeWritesTheEnvelopeAndTheBlock() public {
        string memory name = "UPGSCHED";
        _writeRecords(name);
        DummySchedule s = _schedule(name, "");
        bytes32 id = s.operationId(nextImpl, "");

        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertEq(timelock.getTimestamp(id), block.timestamp + DELAY);

        // The envelope targets the timelock, not the ProxyAdmin.
        string memory envelope = vm.readFile(_envelope(name, "scheduleUpgrade"));
        assertEq(vm.parseJsonAddress(envelope, ".to"), address(timelock));
        assertEq(vm.parseJsonAddress(envelope, ".safe"), safe);
        assertEq(vm.parseJsonString(envelope, ".action"), "scheduleUpgrade");
        assertEq(vm.parseJsonBytes(envelope, ".data"), s.encode(nextImpl, ""));

        // The schedule block holds the ten fields, and no readyAt yet.
        string memory record = vm.readFile(_path(name, "nextImplementation"));
        assertEq(vm.parseJsonBytes32(record, ".schedule.operationId"), id);
        assertEq(vm.parseJsonAddress(record, ".schedule.target"), proxyAdmin);
        assertEq(vm.parseJsonBytes(record, ".schedule.calldata"), s.upgradeCall(nextImpl, ""));
        assertEq(vm.parseJsonBytes(record, ".schedule.data"), "");
        assertEq(vm.parseJsonBytes32(record, ".schedule.predecessor"), bytes32(0));
        assertEq(vm.parseJsonBytes32(record, ".schedule.salt"), s.salt(nextImpl));
        assertEq(vm.parseJsonAddress(record, ".schedule.timelock"), address(timelock));
        assertEq(vm.parseJsonUint(record, ".schedule.delay"), DELAY);
        assertEq(vm.parseJsonAddress(record, ".schedule.proposer"), safe);
        assertEq(vm.parseJsonUint(record, ".schedule.proposedAt"), block.timestamp);
        assertFalse(vm.keyExistsJson(record, ".schedule.readyAt"));
        // The rest of the record survives the write.
        assertEq(vm.parseJsonAddress(record, ".address"), nextImpl);
        assertEq(vm.parseJsonUint(record, ".chainId"), 31337);

        // readSchedule returns the same values.
        (UpgradeManage.Schedule memory sched, bool exists) = s.readSchedule();
        assertTrue(exists);
        assertEq(sched.operationId, id);
        assertEq(sched.target, proxyAdmin);
        assertEq(sched.callData, s.upgradeCall(nextImpl, ""));
        assertEq(sched.salt, s.salt(nextImpl));
        assertFalse(sched.hasReadyAt);

        _removeRecords(name);
    }

    function test_schedule_refusesALiveOperationAndReplacesAnUnconfirmedBlock() public {
        string memory name = "UPGTWICE";
        _writeRecords(name);
        DummySchedule s = _schedule(name, "");
        bytes32 id = s.operationId(nextImpl, "");

        // The chain knows the operation.
        vm.expectRevert(abi.encodeWithSelector(ScheduleUpgrade.AlreadyScheduled.selector, id));
        s.run();

        // The chain forgot it, but the record confirmed it once.
        vm.prank(safe);
        timelock.cancel(id);
        vm.writeJson(vm.toString(block.timestamp + DELAY), _path(name, "nextImplementation"), ".schedule.readyAt");
        vm.expectRevert(abi.encodeWithSelector(ScheduleUpgrade.AlreadyScheduled.selector, id));
        s.run();

        // An unconfirmed block gives way to a new schedule.
        _writeRecords(name);
        s.run();
        vm.prank(safe);
        timelock.cancel(id);
        s.run();
        assertTrue(timelock.isOperationPending(id));

        _removeRecords(name);
    }

    function test_schedule_refusesANextImplementationWithNoCode() public {
        string memory name = "UPGNOCODE";
        nextImpl = makeAddr("empty");
        _writeRecords(name);
        DummySchedule s = new DummySchedule();
        s.configure(name, safe, "");
        vm.expectRevert(abi.encodeWithSelector(ScheduleUpgrade.NextImplementationHasNoCode.selector, nextImpl));
        s.run();
        _removeRecords(name);
    }

    function test_schedule_rejectsAPayloadWithAnUnknownSelector() public {
        string memory name = "UPGSEL";
        _writeRecords(name);
        DummySchedule s = new DummySchedule();
        s.configure(name, safe, hex"deadbeef");
        vm.expectRevert(
            abi.encodeWithSelector(ScheduleUpgrade.UnknownSelector.selector, bytes4(0xdeadbeef), "CounterV2")
        );
        s.run();
        assertFalse(vm.exists(_envelope(name, "scheduleUpgrade")));
        _removeRecords(name);
    }

    /// The simulation runs the whole upgradeAndCall as the timelock. A
    /// payload that reverts stops the run with its own error, before the
    /// envelope and the block exist.
    function test_schedule_stopsOnAPayloadThatReverts() public {
        string memory name = "UPGBADPAY";
        _writeRecords(name);
        DummySchedule s = new DummySchedule();
        s.configure(name, safe, abi.encodeCall(CounterV2.setStep, (0)));
        vm.expectRevert(CounterV2.StepIsZero.selector);
        s.run();
        assertFalse(vm.exists(_envelope(name, "scheduleUpgrade")));
        assertFalse(vm.keyExistsJson(vm.readFile(_path(name, "nextImplementation")), ".schedule"));
        _removeRecords(name);
    }

    /// The simulation leaves no trace: the proxy still runs the old code.
    function test_schedule_withAValidPayloadLeavesTheProxyUnchanged() public {
        string memory name = "UPGPAYSIM";
        _writeRecords(name);
        bytes memory payload = abi.encodeCall(CounterV2.setStep, (3));
        DummySchedule s = _schedule(name, payload);
        assertEq(_implementationOf(proxy), oldImpl);
        assertEq(CounterV1(proxy).count(), 5);
        assertTrue(timelock.isOperationPending(s.operationId(nextImpl, payload)));
        assertEq(vm.parseJsonBytes(vm.readFile(_path(name, "nextImplementation")), ".schedule.data"), payload);
        _removeRecords(name);
    }

    function test_readSchedule_reportsAMissingBlock() public {
        string memory name = "UPGNOBLOCK";
        _writeRecords(name);
        DummySchedule s = new DummySchedule();
        s.configure(name, safe, "");
        (, bool exists) = s.readSchedule();
        assertFalse(exists);
        _removeRecords(name);
        // No record at all reads the same way.
        (, exists) = s.readSchedule();
        assertFalse(exists);
    }
}
