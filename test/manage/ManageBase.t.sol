// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {ManageBase} from "../../script/manage/ManageBase.s.sol";
import {Pause} from "../../script/manage/BitSafeEvmAssetBridge/Pause.s.sol";
import {Unpause} from "../../script/manage/BitSafeEvmAssetBridge/Unpause.s.sol";
import {SetThreshold} from "../../script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol";
import {SetDepositLimits} from "../../script/manage/BitSafeEvmAssetBridge/SetDepositLimits.s.sol";
import {SetWithdrawLimits} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawLimits.s.sol";
import {SetWithdrawRateLimit} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawRateLimit.s.sol";
import {SetWithdrawalHorizon} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawalHorizon.s.sol";
import {RescueERC20} from "../../script/manage/BitSafeEvmAssetBridge/RescueERC20.s.sol";
import {RescueETH} from "../../script/manage/BitSafeEvmAssetBridge/RescueETH.s.sol";
import {RescueSurplus} from "../../script/manage/BitSafeEvmAssetBridge/RescueSurplus.s.sol";
import {VoidWithdrawRequest} from "../../script/manage/BitSafeEvmAssetBridge/VoidWithdrawRequest.s.sol";
import {GrantRole} from "../../script/manage/BitSafeEvmAssetBridge/GrantRole.s.sol";
import {RevokeRole} from "../../script/manage/BitSafeEvmAssetBridge/RevokeRole.s.sol";
import {RenounceRole} from "../../script/manage/BitSafeEvmAssetBridge/RenounceRole.s.sol";
import {BeginDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/BeginDefaultAdminTransfer.s.sol";
import {AcceptDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/AcceptDefaultAdminTransfer.s.sol";
import {CancelDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/CancelDefaultAdminTransfer.s.sol";
import {ChangeDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/ChangeDefaultAdminDelay.s.sol";
import {RollbackDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/RollbackDefaultAdminDelay.s.sol";
import {Status} from "../../script/manage/BitSafeEvmAssetBridge/Status.s.sol";
import {ScheduleUpgrade} from "../../script/manage/upgrade/ScheduleUpgrade.s.sol";
import {ExecuteUpgrade} from "../../script/manage/upgrade/ExecuteUpgrade.s.sol";
import {CancelUpgrade} from "../../script/manage/upgrade/CancelUpgrade.s.sol";
import {ScheduleUpdateDelay} from "../../script/manage/upgrade/ScheduleUpdateDelay.s.sol";
import {ExecuteUpdateDelay} from "../../script/manage/upgrade/ExecuteUpdateDelay.s.sol";
import {CancelUpdateDelay} from "../../script/manage/upgrade/CancelUpdateDelay.s.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// A stand-in action. It overrides the two getters that read external state.
/// A test therefore controls the target and the Safe. The test needs no
/// deployment record and no `SAFE` environment variable.
/// Each leaf fixes its own action name and its own deployment name, so no
/// two test functions read or write one file. forge runs test functions in
/// parallel, and a shared path would corrupt them.
abstract contract DummyAction is ManageBase {
    address private _target;
    address private _safe;

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    function configure(address target_, address safe_) external {
        _target = target_;
        _safe = safe_;
    }

    function target() internal view override returns (address) {
        return _target;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }

    function run(bytes calldata data) external {
        _send(data);
    }

    /// Reaches the two-argument `_send` overload, so a test can pin an
    /// explicit `to` that differs from `target()`.
    function runAt(address to, bytes calldata data) external {
        _send(to, data);
    }
}

/// Used by the one test that reaches the envelope writer.
contract DummyWriteAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyWrite";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGEWRITE";
    }
}

/// Used by the test that expects the target's own revert to bubble up.
contract DummyRevertAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyRevert";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGEREVERT";
    }
}

/// Used by the test that expects TargetHasNoCode.
contract DummyNoCodeAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyNoCode";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGENOCODE";
    }
}

/// Used by the test that asserts a reverted call leaves no envelope file.
contract DummyNoFileAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyNoFile";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGENOFILE";
    }
}

/// Used by the direct-broadcast test. It never reaches the envelope writer.
contract DummyDirectAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyDirect";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGEDIRECT";
    }
}

/// Used by the test that pins the two-argument `_send` overload's `to`.
contract DummyToOverrideAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyToOverride";
    }

    function deploymentName() public pure override returns (string memory) {
        return "MANAGETO";
    }
}

/// Reads a record from disk. Only ONE test function uses it, because it
/// writes a file. Two parallel test functions that write one file corrupt it.
contract RecordReader is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "MANAGETEST";
    }

    function action() public pure override returns (string memory) {
        return "read";
    }

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }
}

/// A Status script with its own deployment name. The name keeps the record
/// file of the test apart from the files of other tests.
contract StatusNamed is Status {
    function deploymentName() public pure override returns (string memory) {
        return "STATUSTIMELOCK";
    }
}

/// A Status script for the test without a record. Its own deployment name
/// keeps its path apart from the path of `StatusNamed`.
contract StatusAbsent is Status {
    function deploymentName() public pure override returns (string memory) {
        return "STATUSNORECORD";
    }
}

/// Reaches the real `target()`, so it reaches the contract guard. Only ONE
/// test function uses it, because it writes files.
contract GuardOkAction is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "GUARDOK";
    }

    function action() public pure override returns (string memory) {
        return "guardOk";
    }

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    function readTarget() external view returns (address) {
        return target();
    }
}

/// The same shape, with its own deployment name. Only ONE test function uses
/// it, because it writes a file.
contract GuardBadAction is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "GUARDBAD";
    }

    function action() public pure override returns (string memory) {
        return "guardBad";
    }

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    function send(bytes calldata data) external {
        _send(data);
    }
}

/// Reaches the deployment-name check without an environment variable.
contract NameCheckAction is ManageBase {
    function action() public pure override returns (string memory) {
        return "nameCheck";
    }

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    function callRequireName(string memory name) external pure returns (string memory) {
        return _requireName(name);
    }
}

/// Reaches the two-argument `_send` through a mismatched record. Only ONE
/// test function uses it, because it writes a file.
contract GuardBadExplicitAction is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "GUARDBADAT";
    }

    function action() public pure override returns (string memory) {
        return "guardBadAt";
    }

    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    function sendAt(address to, bytes calldata data) external {
        _send(to, data);
    }
}

/// A generic script accepts any contract. Only ONE test function uses it,
/// because it writes files.
contract GuardAnyAction is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "GUARDANY";
    }

    function action() public pure override returns (string memory) {
        return "guardAny";
    }

    function contractName() public pure override returns (string memory) {
        return "";
    }

    function acceptsAnyContract() public pure override returns (bool) {
        return true;
    }

    function send(bytes calldata data) external {
        _send(data);
    }
}

contract ManageBaseTest is BridgeTestBase {
    /// Writes the implementation record that the deployment guard reads.
    /// Each caller names its own deployment, so no two test functions touch
    /// one file.
    function _writeImplRecord(string memory name, string memory recorded) private {
        string memory key = string.concat(name, "impl");
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", recorded);
        vm.writeJson(
            vm.serializeAddress(key, "address", address(bridge)),
            string.concat("deployments/", name, ".implementation.31337.json")
        );
    }

    function _removeImplRecord(string memory name) private {
        vm.removeFile(string.concat("deployments/", name, ".implementation.31337.json"));
    }

    function test_safeMode_writesAnEnvelopeAfterProvingTheCallSucceeds() public {
        _writeImplRecord("MANAGEWRITE", "BitSafeEvmAssetBridge");
        DummyWriteAction dummy = new DummyWriteAction();
        dummy.configure(address(bridge), defaultAdmin);
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        // vm.prank spoofs msg.sender only. It does not roll back state, so
        // the call above really ran and the threshold really changed. A real
        // `forge script` run reaches the same local result, and nothing
        // reaches the chain, because Safe mode never passes --broadcast.
        assertEq(bridge.threshold(), 3);

        string memory path = "deployments/.safe/MANAGEWRITE.31337.dummyWrite.json";
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".deployment"), "MANAGEWRITE");
        assertEq(vm.parseJsonAddress(json, ".safe"), defaultAdmin);
        assertEq(vm.parseJsonAddress(json, ".to"), address(bridge));
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        assertEq(vm.parseJsonUint(json, ".operation"), 0);
        assertEq(vm.parseJsonString(json, ".value"), "0");
        assertEq(vm.parseJsonString(json, ".action"), "dummyWrite");
        assertEq(vm.parseJsonBytes(json, ".data"), abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
        vm.removeFile(path);
        _removeImplRecord("MANAGEWRITE");
    }

    function test_safeMode_sendsToTheExplicitTargetNotTheDefaultOne() public {
        // A second, separate bridge stands in for a future ProxyAdmin call:
        // the two-argument overload must record THIS address, not target().
        _writeImplRecord("MANAGETO", "BitSafeEvmAssetBridge");
        BitSafeEvmAssetBridge otherBridge = _deployBridge(address(0));
        DummyToOverrideAction dummy = new DummyToOverrideAction();
        dummy.configure(address(bridge), defaultAdmin);
        dummy.runAt(address(otherBridge), abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        string memory path = "deployments/.safe/MANAGETO.31337.dummyToOverride.json";
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".to"), address(otherBridge));
        assertTrue(address(otherBridge) != address(bridge));
        vm.removeFile(path);
        _removeImplRecord("MANAGETO");
    }

    function test_call_revertsWhenTheTargetHasNoCode() public {
        _writeImplRecord("MANAGENOCODE", "BitSafeEvmAssetBridge");
        address noCode = makeAddr("noCode");
        DummyNoCodeAction dummy = new DummyNoCodeAction();
        dummy.configure(noCode, address(0));
        vm.expectRevert(abi.encodeWithSelector(ManageBase.TargetHasNoCode.selector, noCode));
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
        _removeImplRecord("MANAGENOCODE");
    }

    function test_safeMode_bubblesTheContractRevertWhenTheSafeLacksTheRole() public {
        _writeImplRecord("MANAGEREVERT", "BitSafeEvmAssetBridge");
        DummyRevertAction dummy = new DummyRevertAction();
        dummy.configure(address(bridge), user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.DEFAULT_ADMIN_ROLE()
            )
        );
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
        _removeImplRecord("MANAGEREVERT");
    }

    function test_safeMode_writesNoEnvelopeWhenTheCallReverts() public {
        _writeImplRecord("MANAGENOFILE", "BitSafeEvmAssetBridge");
        DummyNoFileAction dummy = new DummyNoFileAction();
        dummy.configure(address(bridge), user);
        try dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3))) {
            revert("the call must revert");
        } catch {}
        assertFalse(vm.exists("deployments/.safe/MANAGENOFILE.31337.dummyNoFile.json"));
        _removeImplRecord("MANAGENOFILE");
    }

    function test_directMode_sendsTheCallFromTheBroadcaster() public {
        // A direct run takes its sender from the command line. Inside a test
        // the broadcaster is forge-std's DEFAULT_SENDER (inherited from
        // forge-std's CommonBase), confirmed with a throwaway probe that
        // recorded msg.sender under vm.startBroadcast(). The fixture grants
        // that address the role.
        //
        // The role hash is read BEFORE the prank. Reading it inline as a
        // call argument would consume the one-shot prank on that read.
        // grantRole would then run as the test contract, not defaultAdmin.
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(role, DEFAULT_SENDER);

        _writeImplRecord("MANAGEDIRECT", "BitSafeEvmAssetBridge");
        DummyDirectAction dummy = new DummyDirectAction();
        dummy.configure(address(bridge), address(0));
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.pause, ()));

        assertTrue(bridge.paused());
        _removeImplRecord("MANAGEDIRECT");
    }

    function test_recordAddress_readsThePinnedAddressAndChecksTheChain() public {
        RecordReader reader = new RecordReader();
        string memory path = "deployments/MANAGETEST.proxy.31337.json";
        string memory key = "record";
        vm.serializeUint(key, "chainId", 31337);
        string memory json = vm.serializeAddress(key, "address", address(bridge));
        vm.writeJson(json, path);

        assertEq(reader.recordAddress("proxy"), address(bridge));

        // A record whose own chain id disagrees stops the run.
        string memory wrongKey = "wrong";
        vm.serializeUint(wrongKey, "chainId", 1);
        string memory wrongJson = vm.serializeAddress(wrongKey, "address", address(bridge));
        vm.writeJson(wrongJson, path);
        vm.expectRevert(abi.encodeWithSelector(ManageBase.RecordChainMismatch.selector, 1, 31337));
        reader.recordAddress("proxy");

        vm.removeFile(path);
    }

    function test_pause_encodesTheBridgeCall() public {
        Pause pauseScript = new Pause();
        assertEq(pauseScript.encode(), abi.encodeCall(BitSafeEvmAssetBridge.pause, ()));
        assertEq(pauseScript.contractName(), "BitSafeEvmAssetBridge");
        assertEq(pauseScript.action(), "pause");
    }

    function test_status_readsTheLiveConfiguration() public {
        Status status = new Status();
        // The report function takes the addresses as arguments.
        // The test needs no deployment record file.
        status.report(address(bridge), address(0));

        address[] memory holders = new address[](1);
        holders[0] = makeAddr("safe");
        TimelockController timelock = new TimelockController(1 hours, holders, holders, address(0));
        status.report(address(bridge), address(timelock));
    }

    function test_status_timelockAddress_isZeroWithoutARecord() public {
        assertEq((new StatusAbsent()).timelockAddress(), address(0));
    }

    function test_status_timelockAddress_readsTheRecord() public {
        StatusNamed status = new StatusNamed();
        string memory path = "deployments/STATUSTIMELOCK.timelock.31337.json";
        string memory key = "statusTimelock";
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.writeJson(vm.serializeAddress(key, "address", address(0xBEEF)), path);

        address found = status.timelockAddress();
        vm.removeFile(path);

        assertEq(found, address(0xBEEF));
    }

    /// Every management script, the upgrade scripts included, must return a
    /// unique action name.
    /// The action name picks the Safe envelope file path.
    /// Two scripts with one name would overwrite each other's envelope file.
    function test_actionNames_areAllUnique() public {
        string[26] memory names = [
            (new Pause()).action(),
            (new Unpause()).action(),
            (new SetThreshold()).action(),
            (new SetDepositLimits()).action(),
            (new SetWithdrawLimits()).action(),
            (new SetWithdrawRateLimit()).action(),
            (new SetWithdrawalHorizon()).action(),
            (new RescueERC20()).action(),
            (new RescueETH()).action(),
            (new RescueSurplus()).action(),
            (new VoidWithdrawRequest()).action(),
            (new GrantRole()).action(),
            (new RevokeRole()).action(),
            (new RenounceRole()).action(),
            (new BeginDefaultAdminTransfer()).action(),
            (new AcceptDefaultAdminTransfer()).action(),
            (new CancelDefaultAdminTransfer()).action(),
            (new ChangeDefaultAdminDelay()).action(),
            (new RollbackDefaultAdminDelay()).action(),
            (new Status()).action(),
            (new ScheduleUpgrade()).action(),
            (new ExecuteUpgrade()).action(),
            (new CancelUpgrade()).action(),
            (new ScheduleUpdateDelay()).action(),
            (new ExecuteUpdateDelay()).action(),
            (new CancelUpdateDelay()).action()
        ];

        for (uint256 i; i < names.length; ++i) {
            assertTrue(bytes(names[i]).length > 0, "action name must not be empty");
            for (uint256 j = i + 1; j < names.length; ++j) {
                assertTrue(keccak256(bytes(names[i])) != keccak256(bytes(names[j])), "action names must be unique");
            }
        }
    }

    function test_target_readsTheRecordedProxy() public {
        GuardOkAction guard = new GuardOkAction();

        string memory implPath = "deployments/GUARDOK.implementation.31337.json";
        string memory implKey = "guardOkImpl";
        vm.serializeUint(implKey, "chainId", uint256(31337));
        vm.serializeString(implKey, "contractName", "BitSafeEvmAssetBridge");
        vm.writeJson(vm.serializeAddress(implKey, "address", address(bridge)), implPath);

        string memory proxyPath = "deployments/GUARDOK.proxy.31337.json";
        string memory proxyKey = "guardOkProxy";
        vm.serializeUint(proxyKey, "chainId", uint256(31337));
        vm.writeJson(vm.serializeAddress(proxyKey, "address", address(bridge)), proxyPath);

        assertEq(guard.readTarget(), address(bridge));

        vm.removeFile(implPath);
        vm.removeFile(proxyPath);
    }

    /// The guard must run BEFORE the proxy record read. This test writes no
    /// proxy record. A guard that ran second would fail on a missing file
    /// instead of ContractMismatch.
    function test_send_rejectsARecordThatNamesAnotherContract() public {
        GuardBadAction guard = new GuardBadAction();

        string memory implPath = "deployments/GUARDBAD.implementation.31337.json";
        string memory implKey = "guardBadImpl";
        vm.serializeUint(implKey, "chainId", uint256(31337));
        vm.serializeString(implKey, "contractName", "SomeOtherContract");
        vm.writeJson(vm.serializeAddress(implKey, "address", address(bridge)), implPath);

        vm.expectRevert(
            abi.encodeWithSelector(ManageBase.ContractMismatch.selector, "SomeOtherContract", "BitSafeEvmAssetBridge")
        );
        guard.send(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        vm.removeFile(implPath);
    }

    /// The explicit-target form drives a future ProxyAdmin script. It must
    /// check the deployment too, so a wrong DEPLOYMENT cannot reach a live
    /// contract by naming its address.
    function test_sendAt_rejectsARecordThatNamesAnotherContract() public {
        GuardBadExplicitAction guard = new GuardBadExplicitAction();

        string memory implPath = "deployments/GUARDBADAT.implementation.31337.json";
        string memory implKey = "guardBadAtImpl";
        vm.serializeUint(implKey, "chainId", uint256(31337));
        vm.serializeString(implKey, "contractName", "SomeOtherContract");
        vm.writeJson(vm.serializeAddress(implKey, "address", address(bridge)), implPath);

        vm.expectRevert(
            abi.encodeWithSelector(ManageBase.ContractMismatch.selector, "SomeOtherContract", "BitSafeEvmAssetBridge")
        );
        guard.sendAt(address(bridge), abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        vm.removeFile(implPath);
    }

    /// A generic script states that it accepts any contract. The guard then
    /// skips its name comparison, and the send reaches the recorded target.
    function test_send_acceptsAnyContractWhenTheScriptSaysSo() public {
        GuardAnyAction guard = new GuardAnyAction();

        string memory implPath = "deployments/GUARDANY.implementation.31337.json";
        string memory implKey = "guardAnyImpl";
        vm.serializeUint(implKey, "chainId", uint256(31337));
        vm.serializeString(implKey, "contractName", "SomeOtherContract");
        vm.writeJson(vm.serializeAddress(implKey, "address", address(bridge)), implPath);

        string memory proxyPath = "deployments/GUARDANY.proxy.31337.json";
        string memory proxyKey = "guardAnyProxy";
        vm.serializeUint(proxyKey, "chainId", uint256(31337));
        vm.writeJson(vm.serializeAddress(proxyKey, "address", address(bridge)), proxyPath);

        // A view call succeeds from any sender, so direct mode needs no role.
        guard.send(abi.encodeCall(BitSafeEvmAssetBridge.threshold, ()));

        vm.removeFile(implPath);
        vm.removeFile(proxyPath);
    }

    function test_deploymentName_rejectsAnEmptyName() public {
        NameCheckAction checker = new NameCheckAction();
        assertEq(checker.callRequireName("BETH"), "BETH");
        vm.expectRevert(ManageBase.DeploymentNotSet.selector);
        checker.callRequireName("");
    }
}
