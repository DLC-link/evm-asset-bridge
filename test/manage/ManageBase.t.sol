// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {ManageBase} from "../../script/manage/ManageBase.s.sol";
import {Pause} from "../../script/manage/BETH/Pause.s.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// A stand-in action. It overrides the two getters that read the outside
/// world, so a test controls the target and the Safe without a real
/// deployment record or a `SAFE` environment variable.
/// `action()` stays abstract here: `ManageBase.action()` is `pure`, and
/// Solidity refuses an override that widens `pure` to `view`. A leaf
/// contract below fixes each name, so forge runs test functions in
/// parallel without two of them writing the same envelope path.
abstract contract DummyAction is ManageBase {
    address private _target;
    address private _safe;

    function deploymentName() public pure override returns (string memory) {
        return "MANAGETEST";
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
}

/// Used by the test that expects the target's own revert to bubble up.
contract DummyRevertAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyRevert";
    }
}

/// Used by the test that asserts a reverted call leaves no envelope file.
contract DummyNoFileAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyNoFile";
    }
}

/// Used by the direct-broadcast test. It never reaches the envelope writer.
contract DummyDirectAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyDirect";
    }
}

/// Used by the test that pins the two-argument `_send` overload's `to`.
contract DummyToOverrideAction is DummyAction {
    function action() public pure override returns (string memory) {
        return "dummyToOverride";
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
}

contract ManageBaseTest is BridgeTestBase {
    function test_safeMode_writesAnEnvelopeAfterProvingTheCallSucceeds() public {
        DummyWriteAction dummy = new DummyWriteAction();
        dummy.configure(address(bridge), bridgeAdmin);
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        // vm.prank spoofs msg.sender only. It does not roll back state, so
        // the call above really ran and the threshold really changed. A real
        // `forge script` run reaches the same local result, and nothing
        // reaches the chain, because Safe mode never passes --broadcast.
        assertEq(bridge.threshold(), 3);

        string memory path = "deployments/.safe/MANAGETEST.31337.dummyWrite.json";
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".deployment"), "MANAGETEST");
        assertEq(vm.parseJsonAddress(json, ".safe"), bridgeAdmin);
        assertEq(vm.parseJsonAddress(json, ".to"), address(bridge));
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        assertEq(vm.parseJsonUint(json, ".operation"), 0);
        assertEq(vm.parseJsonString(json, ".value"), "0");
        assertEq(vm.parseJsonString(json, ".action"), "dummyWrite");
        assertEq(vm.parseJsonBytes(json, ".data"), abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
        vm.removeFile(path);
    }

    function test_safeMode_sendsToTheExplicitTargetNotTheDefaultOne() public {
        // A second, separate bridge stands in for a future ProxyAdmin call:
        // the two-argument overload must record THIS address, not target().
        BitSafeEvmAssetBridge otherBridge = _deployBridge(address(0));
        DummyToOverrideAction dummy = new DummyToOverrideAction();
        dummy.configure(address(bridge), bridgeAdmin);
        dummy.runAt(address(otherBridge), abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        string memory path = "deployments/.safe/MANAGETEST.31337.dummyToOverride.json";
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".to"), address(otherBridge));
        assertTrue(address(otherBridge) != address(bridge));
        vm.removeFile(path);
    }

    function test_call_revertsWhenTheTargetHasNoCode() public {
        address noCode = makeAddr("noCode");
        DummyRevertAction dummy = new DummyRevertAction();
        dummy.configure(noCode, address(0));
        vm.expectRevert(abi.encodeWithSelector(ManageBase.TargetHasNoCode.selector, noCode));
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
    }

    function test_safeMode_bubblesTheContractRevertWhenTheSafeLacksTheRole() public {
        DummyRevertAction dummy = new DummyRevertAction();
        dummy.configure(address(bridge), user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.BRIDGE_ADMIN_ROLE()
            )
        );
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));
    }

    function test_safeMode_writesNoEnvelopeWhenTheCallReverts() public {
        DummyNoFileAction dummy = new DummyNoFileAction();
        dummy.configure(address(bridge), user);
        try dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3))) {
            revert("the call must revert");
        } catch {}
        assertFalse(vm.exists("deployments/.safe/MANAGETEST.31337.dummyNoFile.json"));
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

        DummyDirectAction dummy = new DummyDirectAction();
        dummy.configure(address(bridge), address(0));
        dummy.run(abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (3)));

        assertEq(bridge.threshold(), 3);
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
        assertEq(pauseScript.deploymentName(), "BETH");
        assertEq(pauseScript.action(), "pause");
    }
}
