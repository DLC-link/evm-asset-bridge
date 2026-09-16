// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ForceSend} from "./mocks/ForceSend.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract RolesTest is BridgeTestBase {
    address internal sentry = makeAddr("sentry");

    function _grantSentry() internal {
        bytes32 role = bridge.SENTRY_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(role, sentry);
    }

    // Cache role ids in locals: an inline bridge.ROLE() view call would
    // consume a pending vm.prank or vm.expectRevert.
    function test_attestor_cannotRenounce() public {
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.expectRevert(BitSafeEvmAssetBridge.AttestorCannotRenounce.selector);
        vm.prank(attestors[0]);
        bridge.renounceRole(role, attestors[0]);
    }

    function test_bridgeAdmin_canRenounce() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.prank(bridgeAdmin);
        bridge.renounceRole(role, bridgeAdmin);
        assertFalse(bridge.hasRole(role, bridgeAdmin));
    }

    function test_defaultAdminTransfer_twoStepWithDelay() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(defaultAdmin);
        bridge.beginDefaultAdminTransfer(newAdmin);
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(newAdmin);
        bridge.acceptDefaultAdminTransfer();
        assertEq(bridge.defaultAdmin(), newAdmin);
    }

    function test_grantAttestor_emitsFullSet() public {
        bytes32 role = bridge.ATTESTOR_ROLE();
        address newAttestor = makeAddr("attestor4");
        address[] memory expected = new address[](4);
        for (uint256 i; i < 3; ++i) {
            expected[i] = attestors[i];
        }
        expected[3] = newAttestor;
        vm.expectEmit(false, false, false, true);
        emit BitSafeEvmAssetBridge.AttestorSetChanged(expected, THRESHOLD);
        vm.prank(defaultAdmin);
        bridge.grantRole(role, newAttestor);
        assertEq(bridge.getAttestors().length, 4);
    }

    function test_grantAttestor_atHalfThreshold_passes() public {
        // A grant may put the threshold at or below half of the set.
        // Governance policy owns the ratio; the contract keeps only the
        // MIN_THRESHOLD floor.
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(role, makeAddr("attestor4"));
        assertEq(bridge.getAttestors().length, 4);
        assertEq(bridge.threshold(), THRESHOLD);
    }

    function test_grantAttestor_withoutRaise_passes() public {
        // The set grows by two grants and nobody raises the threshold.
        // The threshold therefore ends strictly below half, at 2 of 5.
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.startPrank(defaultAdmin);
        bridge.grantRole(role, makeAddr("attestor4"));
        bridge.grantRole(role, makeAddr("attestor5"));
        vm.stopPrank();
        assertEq(bridge.getAttestors().length, 5);
        assertEq(bridge.threshold(), THRESHOLD);
    }

    function test_revokeAttestor_belowThreshold_allowed() public {
        // Emergency offboarding wins; withdrawals halt naturally.
        vm.startPrank(defaultAdmin);
        bridge.revokeRole(bridge.ATTESTOR_ROLE(), attestors[0]);
        bridge.revokeRole(bridge.ATTESTOR_ROLE(), attestors[1]);
        vm.stopPrank();
        assertEq(bridge.getAttestors().length, 1);
        assertGt(bridge.threshold(), bridge.getAttestors().length);
    }

    function test_setThreshold_boundsEnforced() public {
        vm.startPrank(bridgeAdmin);
        bridge.setThreshold(3); // == attestor count: allowed
        assertEq(bridge.threshold(), 3);
        vm.expectRevert(BitSafeEvmAssetBridge.ThresholdOutOfBounds.selector);
        bridge.setThreshold(1); // below MIN_THRESHOLD
        vm.expectRevert(BitSafeEvmAssetBridge.ThresholdOutOfBounds.selector);
        bridge.setThreshold(4); // above attestor count
        vm.stopPrank();
    }

    function test_setThreshold_atHalf_passes() public {
        // Grow the set to 4, then set the threshold to exactly half.
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(role, makeAddr("attestor4"));
        vm.prank(bridgeAdmin);
        bridge.setThreshold(2);
        assertEq(bridge.threshold(), 2);
    }

    function test_setThreshold_belowHalf_passes() public {
        // Grow the set to 5, then set the threshold strictly below half.
        // Both the grants and the setter must accept the ratio.
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.startPrank(defaultAdmin);
        bridge.grantRole(role, makeAddr("attestor4"));
        bridge.grantRole(role, makeAddr("attestor5"));
        vm.stopPrank();
        assertEq(bridge.getAttestors().length, 5);

        vm.prank(bridgeAdmin);
        bridge.setThreshold(2);
        assertEq(bridge.threshold(), 2);
    }

    function test_setThreshold_twoOfThree_passes() public {
        vm.prank(bridgeAdmin);
        bridge.setThreshold(2);
        assertEq(bridge.threshold(), 2);
    }

    function test_setThreshold_requiresBridgeAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.BRIDGE_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        bridge.setThreshold(2);
    }

    function test_setLimits_atomicAndValidated() public {
        vm.startPrank(bridgeAdmin);
        vm.expectEmit(false, false, false, true);
        emit BitSafeEvmAssetBridge.DepositLimitsSet(1 ether, 10 ether);
        bridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(1 ether, 10 ether));
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        bridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(10 ether, 1 ether)); // crossed
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        bridge.setWithdrawLimits(BitSafeEvmAssetBridge.Limits(0, 0)); // zero max
        vm.stopPrank();
    }

    function test_pause_blocksUserAndAttestorPaths() public {
        // Fund the bridge with ETH for valid withdraw test.
        vm.deal(user, 2 ether);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        // Build a fully valid withdraw bundle.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, user, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);

        // Pause and verify both paths are blocked by EnforcedPause.
        vm.prank(bridgeAdmin);
        bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, user, 1 ether, deadline, sigs);

        // Unpause and verify both paths succeed.
        vm.prank(bridgeAdmin);
        bridge.unpause();

        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, user, 1 ether, deadline, sigs);
    }

    function test_rescueERC20_blocksBridgedAsset() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        token.mint(address(erc20Bridge), 5 ether);
        vm.expectRevert(BitSafeEvmAssetBridge.CannotRescueBridgedAsset.selector);
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueERC20(address(token), user, 5 ether);
    }

    function test_rescueERC20_rescuesForeignToken() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(bridge), 5 ether); // ETH instance, any ERC20 is foreign
        vm.prank(bridgeAdmin);
        bridge.rescueERC20(address(stray), user, 5 ether);
        assertEq(stray.balanceOf(user), 5 ether);
    }

    function test_rescueERC20_emitsEvent() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(bridge), 5 ether); // ETH instance, any ERC20 is foreign
        vm.expectEmit(true, true, false, true);
        emit BitSafeEvmAssetBridge.ERC20Rescued(address(stray), user, 5 ether);
        vm.prank(bridgeAdmin);
        bridge.rescueERC20(address(stray), user, 5 ether);
    }

    function test_pause_withoutRole_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.NotPauser.selector, user));
        vm.prank(user);
        bridge.pause();
    }

    function test_sentry_pauses() public {
        _grantSentry();
        vm.prank(sentry);
        bridge.pause();
        assertTrue(bridge.paused());
        // Deposits revert while paused.
        vm.deal(user, 1 ether);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        bridge.depositETH{value: 1e8}(DEPOSIT_ID);
        // Withdrawals revert while paused. whenNotPaused runs before the
        // signature checks, so empty signatures suffice here.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, user, 1e8, block.timestamp + 1 hours, new bytes[](0));
    }

    function test_sentry_cannotUnpause() public {
        _grantSentry();
        vm.prank(sentry);
        bridge.pause();
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sentry, role));
        vm.prank(sentry);
        bridge.unpause();
    }

    function test_bridgeAdmin_stillPausesAndUnpauses() public {
        vm.startPrank(bridgeAdmin);
        bridge.pause();
        bridge.unpause();
        vm.stopPrank();
        assertFalse(bridge.paused());
    }

    function test_sentry_canRenounce() public {
        _grantSentry();
        bytes32 role = bridge.SENTRY_ROLE();
        vm.prank(sentry);
        bridge.renounceRole(role, sentry);
        assertFalse(bridge.hasRole(role, sentry));
    }

    function test_grantSentry_emitsRoleGranted() public {
        bytes32 role = bridge.SENTRY_ROLE();
        vm.expectEmit(true, true, true, true);
        emit IAccessControl.RoleGranted(role, sentry, defaultAdmin);
        vm.prank(defaultAdmin);
        bridge.grantRole(role, sentry);
    }

    function test_revokeSentry_emitsRoleRevoked() public {
        _grantSentry();
        bytes32 role = bridge.SENTRY_ROLE();
        vm.expectEmit(true, true, true, true);
        emit IAccessControl.RoleRevoked(role, sentry, defaultAdmin);
        vm.prank(defaultAdmin);
        bridge.revokeRole(role, sentry);
        assertFalse(bridge.hasRole(role, sentry));
    }

    function test_unpause_requiresBridgeAdmin() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        bridge.unpause();
    }

    function test_setDepositLimits_requiresBridgeAdmin() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        bridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(0, type(uint256).max));
    }

    function test_setWithdrawLimits_requiresBridgeAdmin() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        bridge.setWithdrawLimits(BitSafeEvmAssetBridge.Limits(0, type(uint256).max));
    }

    function test_rescueERC20_requiresBridgeAdmin() public {
        bytes32 role = bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        bridge.rescueERC20(address(0x1), user, 1 ether);
    }

    function test_rescueERC20_zeroTo_reverts() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(bridge), 5 ether); // ETH instance, any ERC20 is foreign
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        vm.prank(bridgeAdmin);
        bridge.rescueERC20(address(stray), address(0), 5 ether);
    }

    function test_rescueETH_rescuesForcedEth() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        ForceSend force = new ForceSend{value: 3 ether}();
        force.boom(payable(address(erc20Bridge)));
        assertEq(address(erc20Bridge).balance, 3 ether);

        vm.prank(bridgeAdmin);
        erc20Bridge.rescueETH(user, 3 ether);
        assertEq(address(erc20Bridge).balance, 0);
        assertEq(user.balance, 3 ether);
    }

    function test_rescueETH_emitsEvent() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        ForceSend force = new ForceSend{value: 3 ether}();
        force.boom(payable(address(erc20Bridge)));

        vm.expectEmit(true, false, false, true);
        emit BitSafeEvmAssetBridge.ETHRescued(user, 3 ether);
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueETH(user, 3 ether);
    }

    function test_rescueETH_blocksBridgedAsset() public {
        vm.expectRevert(BitSafeEvmAssetBridge.CannotRescueBridgedAsset.selector);
        vm.prank(bridgeAdmin);
        bridge.rescueETH(user, 1 ether);
    }

    function test_rescueETH_zeroTo_reverts() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        ForceSend force = new ForceSend{value: 1 ether}();
        force.boom(payable(address(erc20Bridge)));

        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueETH(address(0), 1 ether);
    }

    function test_rescueETH_rejectingReceiver_reverts() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        ForceSend force = new ForceSend{value: 1 ether}();
        force.boom(payable(address(erc20Bridge)));

        RejectingReceiver rejecting = new RejectingReceiver();
        vm.expectRevert(BitSafeEvmAssetBridge.EthTransferFailed.selector);
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueETH(address(rejecting), 1 ether);
        // The failed send leaves the balance in place for a retry.
        assertEq(address(erc20Bridge).balance, 1 ether);
    }

    function test_rescueETH_requiresBridgeAdmin() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        bytes32 role = erc20Bridge.BRIDGE_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        erc20Bridge.rescueETH(user, 1 ether);
    }
}
