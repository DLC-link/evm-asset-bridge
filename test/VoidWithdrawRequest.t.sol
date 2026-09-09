// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract VoidWithdrawRequestTest is BridgeTestBase {
    address internal destination = makeAddr("destination");

    function setUp() public override {
        super.setUp();
        vm.deal(user, 1_000 ether);
        vm.prank(user);
        bridge.depositETH{value: 100 ether}(DEPOSIT_ID);
    }

    /// A fully valid, threshold-signed bundle for REQUEST_ID, as the
    /// coordinator would have collected it before the Canton cancel.
    function _validBundle() internal view returns (bytes[] memory) {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether);
        return _attestorSignatures(digest, 2);
    }

    function test_void_marksUsedAndEmits_transfersNothing() public {
        uint256 bridgeBalanceBefore = address(bridge).balance;
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));

        vm.expectEmit(true, false, false, true);
        emit BitSafeEvmAssetBridge.WithdrawRequestVoided(keccak256(REQUEST_ID), REQUEST_ID);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);

        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
        assertEq(address(bridge).balance, bridgeBalanceBefore);
        assertEq(destination.balance, 0);
    }

    function test_withdraw_afterVoid_reverts() public {
        // The bundle is collected BEFORE the void, exactly the race the void
        // exists to close: it must be dead afterwards even though every
        // signature in it is still valid.
        bytes[] memory sigs = _validBundle();

        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);

        vm.expectRevert(BitSafeEvmAssetBridge.WithdrawRequestAlreadyUsed.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, sigs);
        assertEq(destination.balance, 0);
    }

    function test_void_afterPaid_reverts() public {
        bytes[] memory sigs = _validBundle();
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, sigs);
        assertEq(destination.balance, 1 ether);

        vm.expectRevert(BitSafeEvmAssetBridge.WithdrawRequestAlreadyUsed.selector);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);
    }

    function test_void_twice_reverts() public {
        vm.startPrank(bridgeAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);
        vm.expectRevert(BitSafeEvmAssetBridge.WithdrawRequestAlreadyUsed.selector);
        bridge.voidWithdrawRequest(REQUEST_ID);
        vm.stopPrank();
    }

    function test_void_emptyId_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.EmptyId.selector);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest("");
    }

    function test_void_requiresBridgeAdmin_attestor() public {
        // Attestors sign and submit withdrawals; they must not be able to
        // void one on their own.
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attestors[0], role)
        );
        vm.prank(attestors[0]);
        bridge.voidWithdrawRequest(REQUEST_ID);
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_void_requiresBridgeAdmin_randomAddress() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        bridge.voidWithdrawRequest(REQUEST_ID);
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_void_requiresBridgeAdmin_defaultAdmin() public {
        // The default admin manages roles but does not hold BRIDGE_ADMIN_ROLE.
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, defaultAdmin, role)
        );
        vm.prank(defaultAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_void_worksWhilePaused() public {
        // A pause is the incident response; the void is part of resolving
        // it. Unlike withdraw, it is not gated by whenNotPaused, and the
        // voided id stays dead after unpause.
        bytes[] memory sigs = _validBundle();

        vm.startPrank(bridgeAdmin);
        bridge.pause();
        vm.expectEmit(true, false, false, true);
        emit BitSafeEvmAssetBridge.WithdrawRequestVoided(keccak256(REQUEST_ID), REQUEST_ID);
        bridge.voidWithdrawRequest(REQUEST_ID);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
        bridge.unpause();
        vm.stopPrank();

        vm.expectRevert(BitSafeEvmAssetBridge.WithdrawRequestAlreadyUsed.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, sigs);
    }

    function test_void_isPerId_otherIdsStillPayable() public {
        // Voiding one id must not touch any other id.
        bytes memory otherId = hex"aabbccddee";
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(REQUEST_ID);

        bytes32 digest = bridge.withdrawalDigest(otherId, destination, 1 ether);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        bridge.withdraw(otherId, destination, 1 ether, sigs);
        assertEq(destination.balance, 1 ether);
    }

    function testFuzz_void_anyNonEmptyId(bytes calldata id) public {
        vm.assume(id.length > 0);
        vm.expectEmit(true, false, false, true);
        emit BitSafeEvmAssetBridge.WithdrawRequestVoided(keccak256(id), id);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(id);
        assertTrue(bridge.isWithdrawRequestUsed(id));
    }
}
