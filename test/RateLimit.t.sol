// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RateLimitTest is BridgeTestBase {
    address internal destination = makeAddr("destination");

    uint208 internal constant CAPACITY = 10 ether;
    uint48 internal constant WINDOW = 1 days;

    /// The limiter key the bridge uses: one global bucket.
    bytes32 internal constant KEY = bytes32(0);

    function setUp() public override {
        super.setUp();
        // Move away from the genesis timestamp so warps in both directions
        // stay positive and timestamps are deterministic.
        vm.warp(30 days);
        vm.deal(user, 1_000 ether);
        vm.prank(user);
        bridge.depositETH{value: 500 ether}(DEPOSIT_ID);
    }

    // ------------------------------------------------------------- helpers

    /// Signs and executes a withdrawal with a fresh deadline. A test that
    /// expects a revert builds the arguments with _signedArgs and calls
    /// withdraw itself, so vm.expectRevert targets the state-changing call.
    function _withdraw(bytes memory id, uint256 amount) internal {
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(id, amount);
        vm.prank(attestors[0]);
        bridge.withdraw(id, destination, amount, deadline, sigs);
    }

    /// Builds the deadline and signatures without calling withdraw, so a
    /// test can place vm.expectRevert directly before the state-changing call.
    function _signedArgs(bytes memory id, uint256 amount)
        internal
        view
        returns (uint256 deadline, bytes[] memory sigs)
    {
        deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(id, destination, amount, deadline);
        sigs = _attestorSignatures(digest, THRESHOLD);
    }

    function _setLimit(uint208 capacity, uint48 window) internal {
        vm.prank(bridgeAdmin);
        bridge.setWithdrawRateLimit(capacity, window);
    }

    function _available() internal view returns (uint256 availableBudget) {
        (,, availableBudget) = bridge.withdrawRateLimit();
    }

    // ------------------------------------------- default (zero config = off)

    function test_zeroConfigDefault_limiterIsOff() public {
        // No limit was ever set: a withdrawal far above any plausible
        // capacity passes with zero configuration.
        (uint208 capacity, uint48 window,) = bridge.withdrawRateLimit();
        assertEq(capacity, 0);
        assertEq(window, 0);
        _withdraw(REQUEST_ID, 100 ether);
        assertEq(destination.balance, 100 ether);
    }

    function test_setCapacityZero_reDisables() public {
        _setLimit(1 ether, WINDOW);
        _withdraw(hex"01", 1 ether);

        // The bucket is empty.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", 1 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, 1 ether, deadline, sigs);

        // A capacity of 0 turns the limiter off again.
        _setLimit(0, 0);
        _withdraw(hex"03", 100 ether);
        assertEq(destination.balance, 101 ether);
    }

    // ---------------------------------------------------------------- setter

    function test_setWithdrawRateLimit_storesCapacityAndWindow() public {
        _setLimit(CAPACITY, WINDOW);
        (uint208 capacity, uint48 window, uint256 availableBudget) = bridge.withdrawRateLimit();
        assertEq(capacity, CAPACITY);
        assertEq(window, WINDOW);
        // A fresh bucket starts full.
        assertEq(availableBudget, CAPACITY);
    }

    function test_setWithdrawRateLimit_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BitSafeEvmAssetBridge.WithdrawRateLimitSet(CAPACITY, WINDOW);
        _setLimit(CAPACITY, WINDOW);
    }

    function test_setWithdrawRateLimit_nonAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.BRIDGE_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        bridge.setWithdrawRateLimit(CAPACITY, WINDOW);
    }

    function test_setWithdrawRateLimit_zeroWindowWithCapacity_reverts() public {
        // The library treats a window of 0 as 1 second, which refills the
        // whole bucket every second and silently turns the limit off. The
        // bridge rejects the configuration instead.
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        vm.prank(bridgeAdmin);
        bridge.setWithdrawRateLimit(CAPACITY, 0);
    }

    // ---------------------------------------------------------- enforcement

    function test_withdrawExactlyCapacity_passes() public {
        // The bound is inclusive: the whole capacity in one call passes.
        _setLimit(CAPACITY, WINDOW);
        _withdraw(REQUEST_ID, CAPACITY);
        assertEq(destination.balance, CAPACITY);
        assertEq(_available(), 0);
    }

    function test_withdrawAboveAvailable_revertsWithLimiterError() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(REQUEST_ID, 6 ether);
        // 4 ether remains; 5 ether must revert with the library's error.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", 5 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, 5 ether, deadline, sigs);
    }

    function test_severalWithdrawals_drainOneBucket() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", 3 ether);
        _withdraw(hex"02", 3 ether);
        _withdraw(hex"03", 3 ether);
        assertEq(_available(), 1 ether);

        // 1 ether remains; 2 ether must revert.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"04", 2 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"04", destination, 2 ether, deadline, sigs);

        // The exact remainder still passes.
        _withdraw(hex"05", 1 ether);
        assertEq(_available(), 0);
    }

    // -------------------------------------------------------------- refill

    function test_bucketRefillsLinearly() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", CAPACITY);
        assertEq(_available(), 0);

        // A quarter of the window refills a quarter of the capacity.
        vm.warp(block.timestamp + WINDOW / 4);
        uint256 quarter = uint256(CAPACITY) / 4;
        assertEq(_available(), quarter);

        // One wei above the refilled budget reverts.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", quarter + 1);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, quarter + 1, deadline, sigs);

        // The exact refilled budget passes.
        _withdraw(hex"03", quarter);
        assertEq(_available(), 0);
    }

    function test_fullWindow_refillsToCapacity_neverAbove() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", CAPACITY);

        // A full window refills to exactly the capacity, never above it.
        vm.warp(block.timestamp + WINDOW);
        assertEq(_available(), CAPACITY);
        vm.warp(block.timestamp + 300 days);
        assertEq(_available(), CAPACITY);

        // The capacity passes; the capacity plus one wei reverts.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", uint256(CAPACITY) + 1);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, uint256(CAPACITY) + 1, deadline, sigs);
        _withdraw(hex"03", CAPACITY);
    }

    /// A token bucket has no window edge. After a full spend, the budget at
    /// any later offset is the linear refill, and it never exceeds capacity.
    function testFuzz_noBurstAtAnyOffset(uint256 offset) public {
        offset = bound(offset, 0, 3 * uint256(WINDOW));
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", CAPACITY);

        vm.warp(block.timestamp + offset);
        uint256 refilled = (offset * CAPACITY) / WINDOW;
        uint256 expected = refilled > CAPACITY ? CAPACITY : refilled;
        assertEq(_available(), expected);
        assertLe(_available(), CAPACITY);

        // One wei above the budget always reverts, at every offset.
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", expected + 1);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, expected + 1, deadline, sigs);
    }

    function testFuzz_withdraw_amountAgainstFreshBucket(uint256 amount) public {
        amount = bound(amount, 1, 2 * uint256(CAPACITY));
        _setLimit(CAPACITY, WINDOW);
        (uint256 deadline, bytes[] memory sigs) = _signedArgs(REQUEST_ID, amount);
        if (amount > CAPACITY) {
            vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        }
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, amount, deadline, sigs);
        if (amount <= CAPACITY) {
            assertEq(destination.balance, amount);
            assertEq(_available(), CAPACITY - amount);
        }
    }

    // ------------------------------------------------------ wei denomination

    function test_settingsChangeMidDrain_grantsNoInstantBudget() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", 10 ether); // drain the full bucket
        vm.warp(block.timestamp + 2 hours);
        uint256 before = _available(); // 10 ether * 2h / 24h
        assertEq(before, uint256(10 ether) * 2 hours / WINDOW);

        // A window change mid-drain must not re-price the elapsed time at
        // the new rate: the budget right after the change equals the budget
        // right before it.
        _setLimit(CAPACITY, 1 hours);
        assertEq(_available(), before);

        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", before + 1);
        vm.prank(attestors[0]);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        bridge.withdraw(hex"02", destination, before + 1, deadline, sigs);
    }

    function test_disableThenReEnable_carriesDebt() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(hex"01", 6 ether);
        _setLimit(0, 0); // disable
        vm.warp(block.timestamp + 1 hours);
        // Re-enable: the 6 ether debt survives the disabled period; the
        // bucket does not come back full.
        _setLimit(CAPACITY, WINDOW);
        assertEq(_available(), 4 ether);
    }

    function test_weiDenomination_knownWarpYieldsKnownBudget() public {
        // Capacity and refill rate are wei-denominated: 86_400 wei per
        // 86_400-second window refills exactly 1 wei per second.
        _setLimit(86_400, 86_400);
        _withdraw(hex"01", 86_400);
        assertEq(_available(), 0);

        vm.warp(block.timestamp + 1_234);
        assertEq(_available(), 1_234);

        (uint256 deadline, bytes[] memory sigs) = _signedArgs(hex"02", 1_235);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(hex"02", destination, 1_235, deadline, sigs);
        _withdraw(hex"03", 1_234);
    }

    // --------------------------------------------------------- storage layout

    /// The RefillingBucket replaces the removed 3-slot DailyCap at the same
    /// position: config at base+9, the items mapping at base+10, and one
    function test_storageLayout_configSlotPacksCapacityAndWindow() public {
        _setLimit(CAPACITY, WINDOW);
        bytes32 configSlot = bytes32(uint256(bridge.BRIDGE_STORAGE_LOCATION()) + 9);
        uint256 packed = (uint256(WINDOW) << 208) | uint256(CAPACITY);
        assertEq(uint256(vm.load(address(bridge), configSlot)), packed);
    }

    function test_storageLayout_itemSlotPacksUsedAndTimepoint() public {
        _setLimit(CAPACITY, WINDOW);
        _withdraw(REQUEST_ID, 3 ether);
        bytes32 mappingSlot = bytes32(uint256(bridge.BRIDGE_STORAGE_LOCATION()) + 10);
        bytes32 itemSlot = keccak256(abi.encode(KEY, mappingSlot));
        uint256 packed = (block.timestamp << 208) | 3 ether;
        assertEq(uint256(vm.load(address(bridge), itemSlot)), packed);
    }

    // ----------------------------------------------------------- EIP712 pin

    /// OZ v5.7.0 removed the EIP712 storage fallback for names longer than
    /// 31 bytes. This pins both domain fields inside the ShortString bound.
    function test_eip712DomainFields_fitShortString() public pure {
        assertLe(bytes("BitSafeEvmAssetBridge").length, 31);
        assertLe(bytes("1").length, 31);
    }
}
