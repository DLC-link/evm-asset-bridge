// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {GrantRole} from "../../script/manage/BitSafeEvmAssetBridge/GrantRole.s.sol";
import {SetThreshold} from "../../script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol";
import {RevokeRole} from "../../script/manage/BitSafeEvmAssetBridge/RevokeRole.s.sol";
import {RenounceRole} from "../../script/manage/BitSafeEvmAssetBridge/RenounceRole.s.sol";
import {BeginDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/BeginDefaultAdminTransfer.s.sol";
import {AcceptDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/AcceptDefaultAdminTransfer.s.sol";
import {CancelDefaultAdminTransfer} from "../../script/manage/BitSafeEvmAssetBridge/CancelDefaultAdminTransfer.s.sol";
import {ChangeDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/ChangeDefaultAdminDelay.s.sol";
import {RollbackDefaultAdminDelay} from "../../script/manage/BitSafeEvmAssetBridge/RollbackDefaultAdminDelay.s.sol";

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
}
