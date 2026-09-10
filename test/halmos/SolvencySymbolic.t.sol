// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SymbolicBase} from "./SymbolicBase.t.sol";

/// Symbolic solvency proofs: the bridge balance always covers
/// totalLocked, and every value path moves both together, exactly.
/// The bridge starts empty here, so the accounting is exact end to end.
/// BOUNDS: explicit sequences of up to three calls. The sequence shape
/// is fixed per test; the amounts and timing within it are symbolic.
contract SolvencySymbolic is SymbolicBase {
    /// Per-deposit funding bound. A bound on the test harness, not a
    /// property: two deposits below it can never overflow uint256.
    uint256 internal constant MAX_DEPOSIT = type(uint128).max;

    function setUp() public override {
        super.setUp();
        // halmos leaves every pre-existing ETH balance symbolic, and
        // the solver then picks a bridge balance near 2^256 whose sum
        // with a deposit overflows — more ETH than can exist. Pin the
        // starting balance so the ledger arithmetic is exact.
        vm.deal(address(bridge), 0);
    }

    /// PROPERTY: a deposit increases the balance and totalLocked by
    /// exactly the deposited amount, for every representable amount.
    function check_deposit_movesBalanceAndTotalLockedTogether(bytes32 accountSeed, uint256 amount) public {
        _assumeDepositable(amount);
        _deposit(accountSeed, amount);

        assertEq(bridge.totalLocked(), amount, "totalLocked does not match the deposit");
        assertEq(address(bridge).balance, amount, "the balance does not match the deposit");
    }

    /// PROPERTY: across a deposit-withdraw-deposit sequence the balance
    /// equals totalLocked at every step, whatever succeeds. The
    /// withdrawal outcome is also exactly characterized: it pays if and
    /// only if the requested amount is covered by the deposit.
    function check_solvency_holdsAcrossDepositWithdrawDeposit(
        bytes32 seedD1,
        bytes32 seedW,
        bytes32 seedD2,
        uint256 d1,
        uint256 w,
        uint256 d2,
        uint256 deadline
    ) public {
        _assumeDepositable(d1);
        _assumeDepositable(d2);
        vm.assume(w != 0);
        vm.assume(deadline >= block.timestamp);

        // Sign before the deposits run. halmos registers signature and
        // hash axioms on the path that first executes them, and a
        // registration after a fork loses the axioms on sibling paths
        // (shared caches, halmos 0.3.3). Signing first puts them on
        // the shared prefix of every path.
        bytes memory idW = abi.encodePacked(seedW);
        bytes[] memory sigs = _signedByThreshold(idW, RECEIVER, w, deadline);

        _deposit(seedD1, d1);
        _assertSolvent();

        bool paid = _tryWithdraw(idW, RECEIVER, w, deadline, sigs);
        _assertSolvent();

        _deposit(seedD2, d2);
        _assertSolvent();

        // Exact accounting across the whole sequence.
        uint256 expected = d1 + d2 - (paid ? w : 0);
        assertEq(address(bridge).balance, expected, "the final balance drifted from the ledger");
        assertEq(bridge.totalLocked(), expected, "totalLocked drifted from the ledger");
        // The only reason a fully signed withdrawal fails here is cover.
        assertEq(paid, w <= d1, "the withdrawal outcome does not match the available funds");
    }

    function _assertSolvent() internal view {
        assertGe(address(bridge).balance, bridge.totalLocked(), "the balance no longer covers totalLocked");
    }

    /// The deposit path demands a non-zero multiple of the deposit
    /// unit; the upper bound only keeps the harness sums overflow-free.
    function _assumeDepositable(uint256 amount) internal pure {
        vm.assume(amount != 0 && amount <= MAX_DEPOSIT);
        vm.assume(amount % DEFAULT_DEPOSIT_UNIT == 0);
    }

    function _deposit(bytes32 accountSeed, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        bridge.depositETH{value: amount}(abi.encodePacked(accountSeed));
    }
}
