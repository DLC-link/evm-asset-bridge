// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SymbolicBase} from "./SymbolicBase.t.sol";

/// Symbolic proofs for the interplay of voidWithdrawRequest and
/// withdraw. Both write the same usedWithdrawRequests mapping; these
/// checks prove that neither writer can undo or widen the other.
contract VoidSymbolic is SymbolicBase {
    function setUp() public override {
        super.setUp();
        vm.deal(address(bridge), FUND);
    }

    /// PROPERTY: after a void, no signed bundle for that id ever pays,
    /// for any destination, amount, and deadline.
    function check_void_blocksAnyFutureWithdrawal(bytes32 idSeed, address destination, uint256 amount, uint256 deadline)
        public
    {
        bytes memory id = abi.encodePacked(idSeed);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(id);

        _assumeValidRequest(destination, amount, deadline);
        bytes[] memory sigs = _signedByThreshold(id, destination, amount, deadline);

        assertFalse(_tryWithdraw(id, destination, amount, deadline, sigs), "a voided id paid out");
    }

    /// PROPERTY: a void blocks only its own id. Every other id still
    /// pays. This proves the two ids cannot collide in the mapping.
    function check_void_blocksOnlyTheVoidedId(bytes32 voidSeed, bytes32 paySeed, uint256 amount, uint256 deadline)
        public
    {
        vm.assume(voidSeed != paySeed);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(abi.encodePacked(voidSeed));

        bytes memory payId = abi.encodePacked(paySeed);
        vm.assume(amount != 0 && amount <= FUND);
        vm.assume(deadline >= block.timestamp);
        bytes[] memory sigs = _signedByThreshold(payId, RECEIVER, amount, deadline);

        assertTrue(_tryWithdraw(payId, RECEIVER, amount, deadline, sigs), "a void blocked an unrelated id");
    }

    /// PROPERTY: a paid id can never be voided afterwards. The void
    /// path cannot rewrite history for an id that already released funds.
    function check_void_neverAcceptsAPaidId(bytes32 idSeed, uint256 amount, uint256 deadline) public {
        bytes memory id = abi.encodePacked(idSeed);
        vm.assume(amount != 0 && amount <= FUND);
        vm.assume(deadline >= block.timestamp);
        bytes[] memory sigs = _signedByThreshold(id, RECEIVER, amount, deadline);
        assertTrue(_tryWithdraw(id, RECEIVER, amount, deadline, sigs), "the setup withdrawal reverted");

        vm.prank(bridgeAdmin);
        (bool okVoid,) = address(bridge).call(abi.encodeCall(bridge.voidWithdrawRequest, (id)));
        assertFalse(okVoid, "a paid id was voided");
    }

    /// PROPERTY: a second void of the same id always reverts, so one
    /// void event per id is all monitoring will ever see.
    function check_void_neverAcceptsTheSameIdTwice(bytes32 idSeed) public {
        bytes memory id = abi.encodePacked(idSeed);
        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(id);

        vm.prank(bridgeAdmin);
        (bool okVoid,) = address(bridge).call(abi.encodeCall(bridge.voidWithdrawRequest, (id)));
        assertFalse(okVoid, "one id was voided twice");
    }

    /// PROPERTY: a void moves no value and no accounting: the balance
    /// and totalLocked read the same before and after.
    function check_void_movesNoValue(bytes32 idSeed) public {
        uint256 balanceBefore = address(bridge).balance;
        uint256 lockedBefore = bridge.totalLocked();

        vm.prank(bridgeAdmin);
        bridge.voidWithdrawRequest(abi.encodePacked(idSeed));

        assertEq(address(bridge).balance, balanceBefore, "a void changed the balance");
        assertEq(bridge.totalLocked(), lockedBefore, "a void changed totalLocked");
    }
}
