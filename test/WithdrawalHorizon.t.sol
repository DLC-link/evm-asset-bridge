// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract WithdrawalHorizonTest is BridgeTestBase {
    address internal destination = makeAddr("destination");

    uint256 internal constant HORIZON = 48 hours;

    function setUp() public override {
        super.setUp();
        // A realistic clock: the default 1 leaves no room below the horizon.
        vm.warp(30 days);
        vm.deal(user, 1_000 ether);
        vm.prank(user);
        bridge.depositETH{value: 100 ether}(DEPOSIT_ID);
    }

    function _setHorizon(uint256 horizon) internal {
        vm.prank(bridgeAdmin);
        bridge.setWithdrawalHorizon(horizon);
    }

    function _withdrawWithDeadline(bytes memory id, uint256 deadline) internal {
        bytes32 digest = bridge.withdrawalDigest(id, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.prank(attestors[0]);
        bridge.withdraw(id, destination, 1 ether, deadline, sigs);
    }

    // ------------------------------------------------------------- the bound

    function test_withdraw_deadlineAtHorizon_passes() public {
        // Inclusive bound: deadline == block.timestamp + horizon passes.
        _setHorizon(HORIZON);
        _withdrawWithDeadline(REQUEST_ID, block.timestamp + HORIZON);
        assertEq(destination.balance, 1 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_withdraw_deadlineOneSecondBeyondHorizon_reverts() public {
        _setHorizon(HORIZON);
        uint256 deadline = block.timestamp + HORIZON + 1;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.DeadlineBeyondHorizon.selector, deadline, HORIZON));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_withdraw_zeroHorizon_acceptsFarFutureDeadline() public {
        // The default of 0 disables the bound.
        assertEq(bridge.withdrawalHorizon(), 0);
        _withdrawWithDeadline(REQUEST_ID, block.timestamp + 100 * 365 days);
        assertEq(destination.balance, 1 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function testFuzz_withdraw_horizonBoundary(uint256 offset) public {
        // Deadlines around block.timestamp + horizon: at or below pass,
        // above revert.
        _setHorizon(HORIZON);
        offset = bound(offset, 0, 2 * HORIZON);
        uint256 deadline = block.timestamp + offset;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.prank(attestors[0]);
        if (deadline > block.timestamp + HORIZON) {
            vm.expectRevert(
                abi.encodeWithSelector(BitSafeEvmAssetBridge.DeadlineBeyondHorizon.selector, deadline, HORIZON)
            );
        }
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    // ------------------------------------------------------------- the setter

    function test_setWithdrawalHorizon_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit BitSafeEvmAssetBridge.WithdrawalHorizonSet(HORIZON);
        _setHorizon(HORIZON);
        assertEq(bridge.withdrawalHorizon(), HORIZON);
    }

    function test_setWithdrawalHorizon_nonAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.BRIDGE_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        bridge.setWithdrawalHorizon(HORIZON);
    }

    function test_setWithdrawalHorizon_lowered_rejectsNowTooFarDeadline() public {
        // A deadline legal under the wide horizon becomes illegal after the
        // admin tightens the horizon.
        _setHorizon(HORIZON);
        uint256 deadline = block.timestamp + HORIZON;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);

        _setHorizon(1 hours);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.DeadlineBeyondHorizon.selector, deadline, 1 hours));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }
}
