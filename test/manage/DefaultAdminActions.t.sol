// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {ManageBase} from "../../script/manage/ManageBase.s.sol";
import {GrantRole} from "../../script/manage/BitSafeEvmAssetBridge/GrantRole.s.sol";
import {SetThreshold} from "../../script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol";
import {RevokeRole} from "../../script/manage/BitSafeEvmAssetBridge/RevokeRole.s.sol";
import {RenounceRole} from "../../script/manage/BitSafeEvmAssetBridge/RenounceRole.s.sol";
import {BeginDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/BeginDefaultAdminTransfer.s.sol";
import {AcceptDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/AcceptDefaultAdminTransfer.s.sol";
import {CancelDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/CancelDefaultAdminTransfer.s.sol";
import {ChangeDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/ChangeDefaultAdminDelay.s.sol";
import {RollbackDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/RollbackDefaultAdminDelay.s.sol";

/// The double fixes the three values that come from the environment and
/// the deployment record in a real run.
contract DummyChangeDefaultAdminDelay is ChangeDefaultAdminDelay {
    string private _name;
    address private _target;
    address private _safe;

    function configure(string memory name, address target_, address safe_) external {
        _name = name;
        _target = target_;
        _safe = safe_;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function target() internal view override returns (address) {
        return _target;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }
}

contract DefaultAdminActionsTest is BridgeTestBase {
    function _runAs(address sender, bytes memory data) internal {
        vm.prank(sender);
        (bool ok, bytes memory ret) = address(bridge).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function test_roleByName_mapsTheThreeGrantableRoles() public {
        GrantRole script = new GrantRole();
        assertEq(script.roleByName("BRIDGE_ADMIN"), bridge.BRIDGE_ADMIN_ROLE());
        assertEq(script.roleByName("ATTESTOR"), bridge.ATTESTOR_ROLE());
        assertEq(script.roleByName("SENTRY"), bridge.SENTRY_ROLE());
    }

    function test_roleByName_rejectsTheDefaultAdminRole() public {
        GrantRole script = new GrantRole();
        vm.expectRevert(bytes("use BeginDefaultAdminTransfer for DEFAULT_ADMIN"));
        script.roleByName("DEFAULT_ADMIN");
    }

    function test_roleByName_rejectsAnUnknownName() public {
        GrantRole script = new GrantRole();
        vm.expectRevert(bytes("unknown role name"));
        script.roleByName("OPERATOR");
    }

    function test_setThreshold_fromTheDefaultAdmin() public {
        _runAs(defaultAdmin, new SetThreshold().encode(3));
        assertEq(bridge.threshold(), 3);
    }

    function test_grantRole_grantsSentry() public {
        _runAs(defaultAdmin, new GrantRole().encode("SENTRY", user));
        assertTrue(bridge.hasRole(bridge.SENTRY_ROLE(), user));
    }

    function test_revokeRole_revokesSentry() public {
        _runAs(defaultAdmin, new GrantRole().encode("SENTRY", user));
        _runAs(defaultAdmin, new RevokeRole().encode("SENTRY", user));
        assertFalse(bridge.hasRole(bridge.SENTRY_ROLE(), user));
    }

    function test_renounceRole_dropsTheCallersOwnRole() public {
        _runAs(defaultAdmin, new GrantRole().encode("SENTRY", user));
        _runAs(user, new RenounceRole().encode("SENTRY", user));
        assertFalse(bridge.hasRole(bridge.SENTRY_ROLE(), user));
    }

    function test_defaultAdminTransfer_beginThenAccept() public {
        _runAs(defaultAdmin, new BeginDefaultAdminTransfer().encode(user));
        (address pending, uint48 schedule) = bridge.pendingDefaultAdmin();
        assertEq(pending, user);

        vm.warp(schedule + 1);
        // The incoming admin accepts, not the current one.
        _runAs(user, new AcceptDefaultAdminTransfer().encode());
        assertEq(bridge.defaultAdmin(), user);
    }

    function test_defaultAdminTransfer_cancel() public {
        _runAs(defaultAdmin, new BeginDefaultAdminTransfer().encode(user));
        _runAs(defaultAdmin, new CancelDefaultAdminTransfer().encode());
        (address pending,) = bridge.pendingDefaultAdmin();
        assertEq(pending, address(0));
    }

    function test_changeDefaultAdminDelay_thenRollback() public {
        _runAs(defaultAdmin, new ChangeDefaultAdminDelay().encode(1 days));
        (uint48 newDelay,) = bridge.pendingDefaultAdminDelay();
        assertEq(newDelay, 1 days);

        _runAs(defaultAdmin, new RollbackDefaultAdminDelay().encode());
        (uint48 afterRollback,) = bridge.pendingDefaultAdminDelay();
        assertEq(afterRollback, 0);
        assertEq(bridge.defaultAdminDelay(), ADMIN_DELAY);
    }

    function test_changeDefaultAdminDelay_rejectsAnOutOfRangeValue() public {
        ChangeDefaultAdminDelay script = new ChangeDefaultAdminDelay();
        vm.expectRevert(bytes("delay exceeds uint48"));
        script.encode(uint256(type(uint48).max) + 1);
    }

    /// A typo with extra zeros must not reach the Safe. The maximum itself
    /// passes.
    function test_changeDefaultAdminDelay_run_rejectsADelayAboveTheMaximum() public {
        string memory name = "ADMINDLYMAX";
        string memory implPath = string.concat("deployments/", name, ".implementation.31337.json");
        string memory envelope = string.concat("deployments/.safe/", name, ".31337.changeDefaultAdminDelay.json");
        string memory key = string.concat(name, "impl");
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", "BitSafeEvmAssetBridge");
        vm.writeJson(vm.serializeAddress(key, "address", address(implementation)), implPath);

        DummyChangeDefaultAdminDelay script = new DummyChangeDefaultAdminDelay();
        script.configure(name, address(bridge), defaultAdmin);

        vm.expectRevert(abi.encodeWithSelector(ManageBase.DelayTooLong.selector, 7 days + 1, 7 days));
        script.run(7 days + 1);
        assertFalse(vm.exists(envelope));

        script.run(7 days);
        assertTrue(vm.exists(envelope));
        (uint48 pendingDelay,) = bridge.pendingDefaultAdminDelay();
        assertEq(pendingDelay, 7 days);

        vm.removeFile(envelope);
        vm.removeFile(implPath);
    }
}
