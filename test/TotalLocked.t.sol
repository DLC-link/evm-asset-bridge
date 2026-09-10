// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ForceSend} from "./mocks/ForceSend.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {stdError} from "forge-std/StdError.sol";

contract TotalLockedTest is BridgeTestBase {
    address internal destination = makeAddr("destination");
    address internal rescueTo = makeAddr("rescueTo");

    MockERC20 internal token;
    BitSafeEvmAssetBridge internal erc20Bridge;

    uint256 internal constant DEPOSIT = 10 ether;
    uint256 internal constant STRAY = 1 ether;

    /// Offset of `totalLocked` from BRIDGE_STORAGE_LOCATION, in slots:
    /// asset + assetDecimals + targetDecimals pack into slot 0; threshold 1;
    /// depositLimits 2-3; withdrawLimits 4-5; attestors (AddressSet) 6-7;
    /// usedWithdrawRequests 8; withdrawRateLimit 9-10;
    /// totalLocked 11. test_slotOffset_matchesView verifies this before the
    /// corruption test relies on it.
    uint256 internal constant TOTAL_LOCKED_SLOT_OFFSET = 11;

    function setUp() public override {
        super.setUp(); // `bridge` is the ETH instance
        vm.deal(user, 1_000 ether);

        token = new MockERC20();
        erc20Bridge = _deployBridge(address(token));
        token.mint(user, 1_000 ether);
        vm.prank(user);
        token.approve(address(erc20Bridge), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers

    function _depositETH(uint256 amount) internal {
        vm.prank(user);
        bridge.depositETH{value: amount}(DEPOSIT_ID);
    }

    function _depositERC20(uint256 amount) internal {
        vm.prank(user);
        erc20Bridge.depositERC20(amount, DEPOSIT_ID);
    }

    /// Signs and executes a withdrawal on `b` with a fresh deadline.
    function _withdraw(BitSafeEvmAssetBridge b, bytes memory id, uint256 amount) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = b.withdrawalDigest(id, destination, amount, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.prank(attestors[0]);
        b.withdraw(id, destination, amount, deadline, sigs);
    }

    function _totalLockedSlot(BitSafeEvmAssetBridge b) internal view returns (bytes32) {
        return bytes32(uint256(b.BRIDGE_STORAGE_LOCATION()) + TOTAL_LOCKED_SLOT_OFFSET);
    }

    // ------------------------------------------------------------- counter

    function test_totalLocked_tracksDepositsAndWithdrawals_eth() public {
        assertEq(bridge.totalLocked(), 0);
        _depositETH(DEPOSIT);
        assertEq(bridge.totalLocked(), DEPOSIT);
        _depositETH(5 ether);
        assertEq(bridge.totalLocked(), DEPOSIT + 5 ether);

        _withdraw(bridge, REQUEST_ID, 6 ether);
        assertEq(bridge.totalLocked(), DEPOSIT + 5 ether - 6 ether);
        assertEq(destination.balance, 6 ether);
        // Normal operation keeps the balance equal to the counter.
        assertEq(bridge.surplus(), 0);
    }

    function test_totalLocked_tracksDepositsAndWithdrawals_erc20() public {
        assertEq(erc20Bridge.totalLocked(), 0);
        _depositERC20(DEPOSIT);
        assertEq(erc20Bridge.totalLocked(), DEPOSIT);
        _depositERC20(5 ether);
        assertEq(erc20Bridge.totalLocked(), DEPOSIT + 5 ether);

        _withdraw(erc20Bridge, REQUEST_ID, 6 ether);
        assertEq(erc20Bridge.totalLocked(), DEPOSIT + 5 ether - 6 ether);
        assertEq(token.balanceOf(destination), 6 ether);
        assertEq(erc20Bridge.surplus(), 0);
    }

    // ------------------------------------------------------------- surplus

    function test_surplusZeroInNormalOperation_rescueReverts_eth() public {
        _depositETH(DEPOSIT);
        assertEq(bridge.surplus(), 0);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountExceedsSurplus.selector, 1, 0));
        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(rescueTo, 1);
    }

    function test_surplusZeroInNormalOperation_rescueReverts_erc20() public {
        _depositERC20(DEPOSIT);
        assertEq(erc20Bridge.surplus(), 0);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountExceedsSurplus.selector, 1, 0));
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueSurplus(rescueTo, 1);
    }

    function test_forcedEth_growsSurplus_andRescuePaysItOut() public {
        _depositETH(DEPOSIT);
        new ForceSend{value: STRAY}().boom(payable(address(bridge)));
        assertEq(bridge.surplus(), STRAY);
        assertEq(bridge.totalLocked(), DEPOSIT);

        // One wei above the surplus reverts.
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountExceedsSurplus.selector, STRAY + 1, STRAY));
        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(rescueTo, STRAY + 1);

        // The exact surplus pays out and leaves the counter untouched.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.SurplusRescued(rescueTo, STRAY);
        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(rescueTo, STRAY);
        assertEq(rescueTo.balance, STRAY);
        assertEq(bridge.surplus(), 0);
        assertEq(bridge.totalLocked(), DEPOSIT);
        assertEq(address(bridge).balance, DEPOSIT);
    }

    function test_directErc20Transfer_growsSurplus_andRescuePaysItOut() public {
        _depositERC20(DEPOSIT);
        vm.prank(user);
        token.transfer(address(erc20Bridge), STRAY);
        assertEq(erc20Bridge.surplus(), STRAY);
        assertEq(erc20Bridge.totalLocked(), DEPOSIT);

        // One wei above the surplus reverts.
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountExceedsSurplus.selector, STRAY + 1, STRAY));
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueSurplus(rescueTo, STRAY + 1);

        vm.expectEmit(true, false, false, true, address(erc20Bridge));
        emit BitSafeEvmAssetBridge.SurplusRescued(rescueTo, STRAY);
        vm.prank(bridgeAdmin);
        erc20Bridge.rescueSurplus(rescueTo, STRAY);
        assertEq(token.balanceOf(rescueTo), STRAY);
        assertEq(erc20Bridge.surplus(), 0);
        assertEq(erc20Bridge.totalLocked(), DEPOSIT);
        assertEq(token.balanceOf(address(erc20Bridge)), DEPOSIT);
    }

    function test_rescueSurplus_eth_rejectingReceiver_reverts() public {
        new ForceSend{value: STRAY}().boom(payable(address(bridge)));
        assertEq(bridge.surplus(), STRAY);

        RejectingReceiver rejecting = new RejectingReceiver();
        vm.expectRevert(BitSafeEvmAssetBridge.EthTransferFailed.selector);
        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(address(rejecting), STRAY);
        // The failed send leaves the surplus in place for a retry.
        assertEq(bridge.surplus(), STRAY);
    }

    // -------------------------------------------------- counter corruption

    function test_slotOffset_matchesView() public {
        _depositETH(DEPOSIT);
        // The computed slot must hold what the view reports, on both fixtures.
        assertEq(uint256(vm.load(address(bridge), _totalLockedSlot(bridge))), bridge.totalLocked());
        assertEq(bridge.totalLocked(), DEPOSIT);
        _depositERC20(3 ether);
        assertEq(uint256(vm.load(address(erc20Bridge), _totalLockedSlot(erc20Bridge))), 3 ether);
    }

    function test_corruptedCounter_blocksWithdraw() public {
        _depositETH(DEPOSIT);
        assertEq(uint256(vm.load(address(bridge), _totalLockedSlot(bridge))), DEPOSIT);

        // Corrupt the counter far below the real locked amount.
        vm.store(address(bridge), _totalLockedSlot(bridge), bytes32(uint256(1)));
        assertEq(bridge.totalLocked(), 1);

        // A withdrawal above the counter reverts: the checked subtraction
        // halts on a drifted counter instead of paying unbacked funds.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 6 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 6 ether, deadline, sigs);
    }

    // ------------------------------------------------------ access control

    function test_rescueSurplus_nonAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.BRIDGE_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        bridge.rescueSurplus(rescueTo, 1);
    }

    function test_rescueSurplus_zeroAddress_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(address(0), 1);
    }
}
