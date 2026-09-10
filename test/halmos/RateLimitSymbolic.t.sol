// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SymbolicBase} from "./SymbolicBase.t.sol";

/// Symbolic proof that the withdrawal rate limit caps every bounded
/// sequence of withdrawals.
/// BOUNDS: one concrete configuration (capacity 1000 ether, window 1000
/// seconds), two withdrawals, a gap up to 30 days. The configuration
/// must stay concrete: a symbolic window turns the refill division
/// into nonlinear arithmetic, which the solver cannot decide in
/// reasonable time. The generic for-all-configurations theorem is the
/// OpenZeppelin RateLimiter suite's job, not this repo's.
contract RateLimitSymbolic is SymbolicBase {
    uint208 internal constant CAPACITY = 1_000 ether;
    uint48 internal constant WINDOW = 1_000; // seconds, so the refill rate is 1 ether per second

    function setUp() public override {
        super.setUp();
        vm.deal(address(bridge), FUND);
        vm.prank(bridgeAdmin);
        bridge.setWithdrawRateLimit(CAPACITY, WINDOW);
    }

    /// PROPERTY: two withdrawals with any amounts and any gap between
    /// them never pay out more than the capacity plus the refill for
    /// the elapsed time. A failed attempt consumes no budget, so only
    /// paid amounts count. A single withdrawal is the special case
    /// with the second amount unpayable.
    function check_rateLimit_capsAnyTwoWithdrawals(uint256 a1, uint256 a2, uint256 gap) public {
        vm.assume(a1 != 0 && a2 != 0);
        vm.assume(gap <= 30 days);
        // The rate limiter stores its timepoint as uint48; real
        // timestamps stay far below that. A harness bound, not a property.
        uint256 t0 = block.timestamp;
        vm.assume(t0 >= 1 && t0 <= type(uint40).max);

        // Sign both bundles before the first withdrawal runs. halmos
        // registers signature axioms on the path that first executes
        // them, and a registration after a fork loses the axioms on
        // sibling paths (shared caches, halmos 0.3.3).
        bytes[] memory sigs1 = _signedByThreshold(hex"01", RECEIVER, a1, t0);
        bytes[] memory sigs2 = _signedByThreshold(hex"02", RECEIVER, a2, t0 + gap);

        uint256 paid;
        if (_tryWithdraw(hex"01", RECEIVER, a1, t0, sigs1)) paid += a1;
        vm.warp(t0 + gap);
        if (_tryWithdraw(hex"02", RECEIVER, a2, t0 + gap, sigs2)) paid += a2;

        // The bucket floors its refill, so the continuous-rate bound
        // over the whole gap is an upper bound on its budget.
        uint256 refill = (gap * uint256(CAPACITY)) / WINDOW;
        assertLe(paid, uint256(CAPACITY) + refill, "the sequence paid more than capacity plus refill");
    }
}
