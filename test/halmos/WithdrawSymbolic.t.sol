// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SymbolicBase} from "./SymbolicBase.t.sol";

/// Symbolic proofs for the withdraw path: authorization, message
/// binding, replay protection, exact payout, and the two time bounds.
contract WithdrawSymbolic is SymbolicBase {
    uint256 internal constant HORIZON = 1 days;

    function setUp() public override {
        super.setUp();
        vm.deal(address(bridge), FUND);
    }

    /// PROPERTY: one honest signature plus one outsider signature never
    /// releases funds, for any id, destination, amount, and deadline.
    /// BOUNDS: 2 signatures, 32-byte id, the 2-of-3 fixture set.
    function check_withdraw_rejectsOutsiderSignature(
        bytes32 idSeed,
        address destination,
        uint256 amount,
        uint256 deadline
    ) public {
        bytes memory id = abi.encodePacked(idSeed);
        _assumeValidRequest(destination, amount, deadline);

        bytes32 digest = bridge.withdrawalDigest(id, destination, amount, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(attestorPks[0], digest);
        sigs[1] = _sign(OUTSIDER_KEY, digest);

        assertFalse(_tryWithdraw(id, destination, amount, deadline, sigs), "an outsider signature released funds");
    }

    /// PROPERTY: one attestor alone never reaches the threshold by
    /// signing twice, for any message.
    function check_withdraw_rejectsDuplicateSigner(
        bytes32 idSeed,
        address destination,
        uint256 amount,
        uint256 deadline
    ) public {
        bytes memory id = abi.encodePacked(idSeed);
        _assumeValidRequest(destination, amount, deadline);

        bytes32 digest = bridge.withdrawalDigest(id, destination, amount, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(attestorPks[0], digest);
        sigs[1] = _sign(attestorPks[0], digest);

        assertFalse(_tryWithdraw(id, destination, amount, deadline, sigs), "a duplicated signature reached threshold");
    }

    /// PROPERTY: fewer signatures than the threshold never release
    /// funds, for any message.
    function check_withdraw_rejectsBelowThreshold(bytes32 idSeed, address destination, uint256 amount, uint256 deadline)
        public
    {
        bytes memory id = abi.encodePacked(idSeed);
        _assumeValidRequest(destination, amount, deadline);

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(attestorPks[0], bridge.withdrawalDigest(id, destination, amount, deadline));

        assertFalse(_tryWithdraw(id, destination, amount, deadline, sigs), "a single signature released funds");
    }

    /// PROPERTY: two different withdrawal tuples never share a digest.
    /// Any change to any field changes what the attestors sign. This is
    /// the provable half of message binding: with distinct digests, a
    /// signature over one tuple transfers to another only by forging
    /// ECDSA, which every verification model assumes impossible. (The
    /// halmos ecrecover model cannot state unforgeability across
    /// digests directly, so the signature-level variant of this test
    /// would report spurious counterexamples.)
    function check_withdrawalDigest_bindsTheExactMessage(
        bytes32 idSeedA,
        address destA,
        uint256 amountA,
        uint256 deadlineA,
        bytes32 idSeedB,
        address destB,
        uint256 amountB,
        uint256 deadlineB
    ) public view {
        vm.assume(idSeedA != idSeedB || destA != destB || amountA != amountB || deadlineA != deadlineB);

        bytes32 digestA = bridge.withdrawalDigest(abi.encodePacked(idSeedA), destA, amountA, deadlineA);
        bytes32 digestB = bridge.withdrawalDigest(abi.encodePacked(idSeedB), destB, amountB, deadlineB);

        assertTrue(digestA != digestB, "two different messages share a digest");
    }

    /// PROPERTY: a fully valid withdrawal pays the destination exactly
    /// `amount`, reduces the bridge by exactly `amount`, and marks the
    /// id used — and it never reverts.
    function check_withdraw_paysTheExactAmount(bytes32 idSeed, uint256 amount, uint256 deadline) public {
        bytes memory id = abi.encodePacked(idSeed);
        vm.assume(amount != 0 && amount <= FUND);
        vm.assume(deadline >= block.timestamp);

        bytes[] memory sigs = _signedByThreshold(id, RECEIVER, amount, deadline);

        assertTrue(_tryWithdraw(id, RECEIVER, amount, deadline, sigs), "a valid withdrawal reverted");
        assertEq(RECEIVER.balance, amount, "the destination did not receive the exact amount");
        assertEq(address(bridge).balance, FUND - amount, "the bridge did not pay the exact amount");
        assertTrue(bridge.isWithdrawRequestUsed(id), "the id was not marked used");
    }

    /// PROPERTY: one id pays at most once. A second bundle with the
    /// same id never pays, even re-signed for a new destination,
    /// amount, and deadline.
    function check_withdraw_neverPaysTheSameIdTwice(
        bytes32 idSeed,
        uint256 amountA,
        uint256 deadlineA,
        address destB,
        uint256 amountB,
        uint256 deadlineB
    ) public {
        bytes memory id = abi.encodePacked(idSeed);
        vm.assume(amountA != 0 && amountA <= FUND);
        vm.assume(deadlineA >= block.timestamp);
        _assumeValidRequest(destB, amountB, deadlineB);

        bytes[] memory sigsA = _signedByThreshold(id, RECEIVER, amountA, deadlineA);
        assertTrue(_tryWithdraw(id, RECEIVER, amountA, deadlineA, sigsA), "the first withdrawal reverted");

        bytes[] memory sigsB = _signedByThreshold(id, destB, amountB, deadlineB);
        assertFalse(_tryWithdraw(id, destB, amountB, deadlineB, sigsB), "one id paid twice");
    }

    /// PROPERTY: the deadline bound is inclusive and exact. The call
    /// succeeds when `deadline >= block.timestamp` and reverts when
    /// `deadline < block.timestamp`, with no off-by-one, at any time.
    function check_withdraw_deadlineBoundIsInclusiveAndExact(
        bytes32 idSeed,
        uint256 amount,
        uint256 deadline,
        uint256 ts
    ) public {
        // The time bound avoids the uint48 cast overflow inside the OZ
        // Time library, which is unreachable for real timestamps.
        vm.assume(ts >= 1 && ts <= type(uint40).max);
        vm.warp(ts);
        bytes memory id = abi.encodePacked(idSeed);
        vm.assume(amount != 0 && amount <= FUND);

        bytes[] memory sigs = _signedByThreshold(id, RECEIVER, amount, deadline);
        bool ok = _tryWithdraw(id, RECEIVER, amount, deadline, sigs);

        assertEq(ok, deadline >= ts, "the deadline bound is not exactly inclusive");
    }

    /// PROPERTY: with a horizon set, the call succeeds exactly when
    /// `block.timestamp <= deadline <= block.timestamp + horizon`.
    /// Both bounds are inclusive, with no off-by-one, at any time.
    function check_withdraw_horizonBoundIsInclusiveAndExact(
        bytes32 idSeed,
        uint256 amount,
        uint256 deadline,
        uint256 ts
    ) public {
        vm.assume(ts >= 1 && ts <= type(uint40).max);
        vm.warp(ts);
        vm.prank(bridgeAdmin);
        bridge.setWithdrawalHorizon(HORIZON);
        bytes memory id = abi.encodePacked(idSeed);
        vm.assume(amount != 0 && amount <= FUND);

        bytes[] memory sigs = _signedByThreshold(id, RECEIVER, amount, deadline);
        bool ok = _tryWithdraw(id, RECEIVER, amount, deadline, sigs);

        assertEq(ok, deadline >= ts && deadline <= ts + HORIZON, "the horizon bound is not exactly inclusive");
    }
}
