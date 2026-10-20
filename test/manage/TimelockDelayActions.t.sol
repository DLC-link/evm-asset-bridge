// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ManageBase} from "../../script/manage/ManageBase.s.sol";
import {TimelockManage} from "../../script/manage/upgrade/TimelockManage.s.sol";
import {UpdateDelayManage} from "../../script/manage/upgrade/UpdateDelayManage.s.sol";
import {ScheduleUpdateDelay} from "../../script/manage/upgrade/ScheduleUpdateDelay.s.sol";
import {ExecuteUpdateDelay} from "../../script/manage/upgrade/ExecuteUpdateDelay.s.sol";
import {CancelUpdateDelay} from "../../script/manage/upgrade/CancelUpdateDelay.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// Each double fixes the two values that come from the environment in a
/// real run. The timelock record comes from the file the test writes, so the
/// tests cover the record read too.
contract DummyScheduleDelay is ScheduleUpdateDelay {
    string private _name;
    address private _safe;

    function configure(string memory name, address safe_) external {
        _name = name;
        _safe = safe_;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }
}

contract DummyExecuteDelay is ExecuteUpdateDelay {
    string private _name;
    address private _safe;

    function configure(string memory name, address safe_) external {
        _name = name;
        _safe = safe_;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }
}

contract DummyCancelDelay is CancelUpdateDelay {
    string private _name;
    address private _safe;

    function configure(string memory name, address safe_) external {
        _name = name;
        _safe = safe_;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }
}

/// The fixture: a timelock whose delay is one hour. The Safe is the
/// proposer, canceller and executor. The scripts read only the `timelock`
/// record.
contract TimelockDelayActionsTest is Test {
    uint256 internal constant DELAY = 1 hours;
    uint256 internal constant NEW = 2 hours;

    address internal safe = makeAddr("safe");
    address internal outsider = makeAddr("outsider");
    TimelockController internal timelock;

    function setUp() public {
        address[] memory holders = new address[](1);
        holders[0] = safe;
        timelock = new TimelockController(DELAY, holders, holders, address(0));
    }

    function _path(string memory name, string memory role) internal pure returns (string memory) {
        return string.concat("deployments/", name, ".", role, ".31337.json");
    }

    function _envelope(string memory name, string memory action) internal pure returns (string memory) {
        return string.concat("deployments/.safe/", name, ".31337.", action, ".json");
    }

    function _writeRecord(string memory name) internal {
        string memory key = string.concat(name, "timelock");
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.writeJson(vm.serializeAddress(key, "address", address(timelock)), _path(name, "timelock"));
    }

    function _clean(string memory name) internal {
        vm.removeFile(_path(name, "timelock"));
        string[3] memory actions = ["scheduleUpdateDelay", "executeUpdateDelay", "cancelUpdateDelay"];
        for (uint256 i; i < actions.length; ++i) {
            string memory envelope = _envelope(name, actions[i]);
            if (vm.exists(envelope)) {
                vm.removeFile(envelope);
            }
        }
    }

    function _schedule(string memory name) internal returns (DummyScheduleDelay s) {
        s = new DummyScheduleDelay();
        s.configure(name, safe);
    }

    function _execute(string memory name) internal returns (DummyExecuteDelay e) {
        e = new DummyExecuteDelay();
        e.configure(name, safe);
    }

    function _cancel(string memory name) internal returns (DummyCancelDelay c) {
        c = new DummyCancelDelay();
        c.configure(name, safe);
    }

    function test_schedule_fromTheSafeWritesTheEnvelope() public {
        string memory name = "DLYSCHED";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);

        assertTrue(timelock.isOperationPending(s.delayOperationId(NEW)));
        string memory envelope = vm.readFile(_envelope(name, "scheduleUpdateDelay"));
        assertEq(vm.parseJsonAddress(envelope, ".to"), address(timelock));
        assertEq(vm.parseJsonAddress(envelope, ".safe"), safe);
        assertEq(vm.parseJsonString(envelope, ".action"), "scheduleUpdateDelay");
        assertEq(vm.parseJsonBytes(envelope, ".data"), s.encode(NEW));
        _clean(name);
    }

    function test_schedule_revertsForANonProposer() public {
        string memory name = "DLYNOPROP";
        _writeRecord(name);
        DummyScheduleDelay s = new DummyScheduleDelay();
        s.configure(name, outsider);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, timelock.PROPOSER_ROLE()
            )
        );
        s.run(NEW);

        assertFalse(vm.exists(_envelope(name, "scheduleUpdateDelay")));
        _clean(name);
    }

    /// The schedule refuses a delay above the maximum. An extra zero in DELAY
    /// would otherwise set a very long delay.
    function test_schedule_rejectsADelayAboveTheMaximum() public {
        string memory name = "DLYCEIL";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        vm.expectRevert(abi.encodeWithSelector(ManageBase.DelayTooLong.selector, 7 days + 1, 7 days));
        s.run(7 days + 1);
        assertFalse(vm.exists(_envelope(name, "scheduleUpdateDelay")));

        // The maximum itself passes.
        s.run(7 days);
        assertTrue(timelock.isOperationPending(s.delayOperationId(7 days)));
        _clean(name);
    }

    function test_schedule_rejectsTheCurrentDelay() public {
        string memory name = "DLYSAME";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        vm.expectRevert(abi.encodeWithSelector(UpdateDelayManage.DelayUnchanged.selector, 1 hours));
        s.run(1 hours);
        assertFalse(vm.exists(_envelope(name, "scheduleUpdateDelay")));
        _clean(name);
    }

    function test_schedule_refusesAPendingOperation() public {
        string memory name = "DLYTWICE";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);
        bytes32 id = s.delayOperationId(NEW);

        vm.expectRevert(abi.encodeWithSelector(TimelockManage.AlreadyScheduled.selector, id));
        s.run(NEW);
        _clean(name);
    }

    /// The transition 1h to 2h gives one operation id per timelock. After
    /// the sequence 1h to 2h, 2h to 1h, the third schedule meets the first
    /// operation in state `Done`.
    function test_schedule_refusesATransitionThatAlreadyRan() public {
        string memory name = "DLYDONE";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        DummyExecuteDelay e = _execute(name);

        s.run(NEW);
        bytes32 id = s.delayOperationId(NEW);
        vm.warp(block.timestamp + DELAY);
        e.run(NEW);
        assertEq(timelock.getMinDelay(), NEW);

        s.run(DELAY);
        vm.warp(block.timestamp + NEW);
        e.run(DELAY);
        assertEq(timelock.getMinDelay(), DELAY);

        assertEq(s.delayOperationId(NEW), id);
        vm.expectRevert(abi.encodeWithSelector(TimelockManage.OperationDone.selector, id));
        s.run(NEW);
        _clean(name);
    }

    function test_execute_revertsBeforeTheDelayPasses() public {
        string memory name = "DLYEARLY";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);
        bytes32 id = s.delayOperationId(NEW);
        uint256 readyAt = timelock.getTimestamp(id);
        DummyExecuteDelay e = _execute(name);

        vm.expectRevert(
            abi.encodeWithSelector(TimelockManage.OperationNotReady.selector, id, readyAt, readyAt - block.timestamp)
        );
        e.run(NEW);

        assertEq(timelock.getMinDelay(), DELAY);
        assertFalse(vm.exists(_envelope(name, "executeUpdateDelay")));
        _clean(name);
    }

    function test_execute_afterTheDelayChangesTheMinDelay() public {
        string memory name = "DLYEXEC";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);
        bytes32 id = s.delayOperationId(NEW);
        DummyExecuteDelay e = _execute(name);
        // The salt holds the live delay, so the call is read before the change.
        bytes memory expected = e.encode(NEW);

        vm.warp(block.timestamp + 1 hours);
        e.run(NEW);

        assertEq(timelock.getMinDelay(), NEW);
        assertTrue(timelock.isOperationDone(id));
        string memory envelope = vm.readFile(_envelope(name, "executeUpdateDelay"));
        assertEq(vm.parseJsonAddress(envelope, ".to"), address(timelock));
        assertEq(vm.parseJsonBytes(envelope, ".data"), expected);
        _clean(name);
    }

    /// The scripts derive the id from the live delay and the new delay. A
    /// new delay that nobody scheduled therefore names no operation.
    function test_executeAndCancel_withAnotherDelayReportNoOperation() public {
        string memory name = "DLYOTHER";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);
        DummyExecuteDelay e = _execute(name);
        DummyCancelDelay c = _cancel(name);
        bytes32 other = e.delayOperationId(3 hours);

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(TimelockManage.OperationNotOnChain.selector, other));
        e.run(3 hours);
        vm.expectRevert(abi.encodeWithSelector(TimelockManage.OperationNotOnChain.selector, other));
        c.run(3 hours);
        _clean(name);
    }

    function test_cancel_removesThePendingOperation() public {
        string memory name = "DLYCANCEL";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        s.run(NEW);
        bytes32 id = s.delayOperationId(NEW);
        DummyCancelDelay c = _cancel(name);

        c.run(NEW);
        assertEq(uint8(timelock.getOperationState(id)), uint8(TimelockController.OperationState.Unset));
        string memory envelope = vm.readFile(_envelope(name, "cancelUpdateDelay"));
        assertEq(vm.parseJsonAddress(envelope, ".to"), address(timelock));
        assertEq(vm.parseJsonBytes(envelope, ".data"), c.encode(NEW));

        // A cancelled operation does not count as done. The same change schedules again.
        s.run(NEW);
        assertTrue(timelock.isOperationPending(id));
        _clean(name);
    }

    /// A salt or a payload that differed between the scripts would schedule
    /// an operation nobody can execute.
    function test_theThreeScriptsAgreeOnTheOperation() public {
        string memory name = "DLYAGREE";
        _writeRecord(name);
        DummyScheduleDelay s = _schedule(name);
        DummyExecuteDelay e = _execute(name);
        DummyCancelDelay c = _cancel(name);

        bytes32 id = s.delayOperationId(NEW);
        assertEq(e.delayOperationId(NEW), id);
        assertEq(c.delayOperationId(NEW), id);

        s.run(NEW);
        string memory envelope = vm.readFile(_envelope(name, "scheduleUpdateDelay"));
        bytes memory scheduled = vm.parseJsonBytes(envelope, ".data");
        // Drop the selector, then read the six arguments of `schedule`.
        (address to, uint256 value, bytes memory payload, bytes32 pred, bytes32 salt, uint256 delay) =
            abi.decode(_tail(scheduled), (address, uint256, bytes, bytes32, bytes32, uint256));
        assertEq(bytes4(scheduled), TimelockController.schedule.selector);
        assertEq(payload, abi.encodeCall(TimelockController.updateDelay, (NEW)));
        assertEq(to, address(timelock));
        assertEq(value, 0);
        assertEq(pred, bytes32(0));
        assertEq(delay, DELAY);
        assertEq(salt, keccak256(abi.encodePacked(name, "-delay-", DELAY, NEW)));
        assertEq(id, timelock.hashOperation(to, value, payload, pred, salt));

        // Execute encodes the same arguments. Cancel encodes the same id.
        assertEq(e.encode(NEW), abi.encodeCall(TimelockController.execute, (to, value, payload, pred, salt)));
        assertEq(c.encode(NEW), abi.encodeCall(TimelockController.cancel, (id)));

        assertEq(s.action(), "scheduleUpdateDelay");
        assertEq(e.action(), "executeUpdateDelay");
        assertEq(c.action(), "cancelUpdateDelay");
        _clean(name);
    }

    function test_schedule_withoutATimelockRecordStops() public {
        DummyScheduleDelay s = _schedule("DLYNORECORD");
        // `vm.readFile` reverts on the missing file.
        vm.expectRevert();
        s.run(NEW);
        assertFalse(vm.exists(_envelope("DLYNORECORD", "scheduleUpdateDelay")));
    }

    function _tail(bytes memory input) internal pure returns (bytes memory out) {
        out = new bytes(input.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = input[i + 4];
        }
    }
}
