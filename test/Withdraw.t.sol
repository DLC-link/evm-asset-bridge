// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantReceiver} from "./mocks/ReentrantReceiver.sol";
import {IBridgeWithdraw} from "./mocks/ReentrantReceiver.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract WithdrawTest is BridgeTestBase {
    address internal destination = makeAddr("destination");
    // Fixture default: a deadline safely in the future for every test that
    // does not exercise expiry itself.
    uint256 internal defaultDeadline;

    function setUp() public override {
        super.setUp();
        defaultDeadline = block.timestamp + 1 hours;
        vm.deal(user, 1_000 ether);
        vm.prank(user);
        bridge.depositETH{value: 100 ether}(DEPOSIT_ID);
    }

    function _withdraw(bytes memory id, address dest, uint256 amount, uint256 sigCount) internal {
        bytes32 digest = bridge.withdrawalDigest(id, dest, amount, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, sigCount);
        vm.prank(attestors[0]);
        bridge.withdraw(id, dest, amount, defaultDeadline, sigs);
    }

    function test_withdrawETH_transfersAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit BitSafeEvmAssetBridge.Withdraw(keccak256(REQUEST_ID), REQUEST_ID, destination, 5 ether, defaultDeadline);
        _withdraw(REQUEST_ID, destination, 5 ether, 2);
        assertEq(destination.balance, 5 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_withdrawERC20_transfers() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        token.mint(user, 100 ether);
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 50 ether);
        erc20Bridge.depositERC20(50 ether, DEPOSIT_ID);
        vm.stopPrank();

        bytes32 digest = erc20Bridge.withdrawalDigest(REQUEST_ID, destination, 7 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        erc20Bridge.withdraw(REQUEST_ID, destination, 7 ether, defaultDeadline, sigs);
        assertEq(token.balanceOf(destination), 7 ether);
    }

    function test_withdraw_replay_reverts() public {
        _withdraw(REQUEST_ID, destination, 1 ether, 2);
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(BitSafeEvmAssetBridge.WithdrawRequestAlreadyUsed.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_expiredDeadline_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.warp(deadline + 1);
        vm.prank(attestors[0]);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.WithdrawalExpired.selector, deadline));
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_withdraw_atDeadline_passes() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.warp(deadline); // inclusive bound
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function testFuzz_withdraw_deadlineValue(uint256 deadline) public {
        // Start from a realistic clock so past deadlines form a real range.
        vm.warp(30 days);
        deadline = bound(deadline, 0, block.timestamp + 365 days);
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.prank(attestors[0]);
        if (block.timestamp > deadline) {
            vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.WithdrawalExpired.selector, deadline));
        }
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function testFuzz_withdraw_deadlineBoundary(uint256 offset) public {
        offset = bound(offset, 0, 30 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, THRESHOLD);
        vm.warp(block.timestamp + offset);
        vm.prank(attestors[0]);
        if (block.timestamp > deadline) {
            vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.WithdrawalExpired.selector, deadline));
        }
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_withdraw_duplicateSigner_reverts() public {
        // The same key signing twice must not satisfy the threshold.
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(attestorPks[0], digest);
        sigs[1] = _sign(attestorPks[0], digest); // identical signer
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.DuplicateSigner.selector, attestors[0]));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_unorderedSigners_succeeds() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(attestorPks[1], digest);
        sigs[1] = _sign(attestorPks[0], digest); // descending order
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
        assertEq(destination.balance, 1 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_withdraw_nonAttestorSigner_reverts() public {
        (address rogue, uint256 roguePk) = makeAddrAndKey("rogue");
        rogue; // silence unused
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(attestorPks[0], digest);
        sigs[1] = _sign(roguePk, digest);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.SignerIsNotAttestor.selector, vm.addr(roguePk)));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_extraRogueSignatureAfterValidThreshold_reverts() public {
        // Every provided signature must be validated -- no early exit once
        // the threshold count is reached. Two real attestor signatures plus
        // a third from a rogue key must still fail on the rogue signer, even
        // when the rogue signature comes AFTER the threshold count of valid
        // ones (index 2, not index 0) -- a regression that only checks the
        // first `threshold` signatures must not pass this test.
        (address rogueAddr, uint256 roguePk) = makeAddrAndKey("rogue");

        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(attestorPks[0], digest);
        sigs[1] = _sign(attestorPks[1], digest);
        sigs[2] = _sign(roguePk, digest); // rogue after the threshold count

        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.SignerIsNotAttestor.selector, rogueAddr));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_malformedSignature_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes memory badSig = _sign(attestorPks[0], digest);
        badSig[badSig.length - 1] = 0; // corrupt the v byte
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = badSig;
        sigs[1] = _sign(attestorPks[1], digest);
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidSignature.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_allAttestorSignatures_succeeds() public {
        // Threshold is 2, but supplying every attestor's valid signature
        // (3 of 3) must still succeed -- extra correct signatures are not
        // penalized, and the loop validates each one it is given.
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 3);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
        assertEq(destination.balance, 1 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_withdraw_revokedAttestorSignature_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        bytes32 role = bridge.ATTESTOR_ROLE();
        vm.prank(defaultAdmin);
        bridge.revokeRole(role, attestors[0]);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.SignerIsNotAttestor.selector, attestors[0]));
        vm.prank(attestors[1]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_tooFewSignatures_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 1);
        vm.expectRevert(BitSafeEvmAssetBridge.NotEnoughSignatures.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_callerWithoutAttestorRole_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, bridge.ATTESTOR_ROLE()
            )
        );
        vm.prank(user);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_tamperedField_reverts() public {
        // signatures over amount 1 ether must not authorize amount 2 ether
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(); // recovered signers are garbage, role check fails
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 2 ether, defaultDeadline, sigs);
    }

    function test_withdraw_tamperedDeadline_reverts() public {
        // signatures over one deadline must not authorize a later deadline
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(); // recovered signers are garbage, role check fails
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline + 1, sigs);
    }

    function test_withdraw_zeroDestination_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, address(0), 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidDestination.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, address(0), 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_bridgeAsDestination_reverts() public {
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, address(bridge), 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidDestination.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, address(bridge), 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_emptyId_reverts() public {
        bytes32 digest = bridge.withdrawalDigest("", destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(BitSafeEvmAssetBridge.EmptyId.selector);
        vm.prank(attestors[0]);
        bridge.withdraw("", destination, 1 ether, defaultDeadline, sigs);
    }

    function test_withdraw_degenerateThresholdZero_reverts() public {
        // A zeroed quorum must not open the bridge.
        // threshold is the second word of the namespaced struct.
        bytes32 slot = bytes32(uint256(bridge.BRIDGE_STORAGE_LOCATION()) + 1);
        vm.store(address(bridge), slot, bytes32(0));
        assertEq(bridge.threshold(), 0);
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(BitSafeEvmAssetBridge.ThresholdOutOfBounds.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, noSigs);
    }

    function test_withdraw_reentrancy_cannotDoubleSpend() public {
        ReentrantReceiver attacker = new ReentrantReceiver();
        // Grant ATTESTOR_ROLE to the attacker contract itself so the reentrant
        // call clears onlyRole and actually reaches nonReentrant -- otherwise
        // the inner call would die on the role check before ever exercising
        // the guard. Signatures below still come from real attestor keys;
        // granting the role only changes who may *call* withdraw.
        bytes32 attestorRole = bridge.ATTESTOR_ROLE();
        // The grant grows the set to 4, so the threshold must rise to 3 first.
        vm.prank(bridgeAdmin);
        bridge.setThreshold(3);
        vm.prank(defaultAdmin);
        bridge.grantRole(attestorRole, address(attacker));

        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, address(attacker), 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 3);
        attacker.arm(IBridgeWithdraw(address(bridge)), REQUEST_ID, 1 ether, defaultDeadline, sigs);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, address(attacker), 1 ether, defaultDeadline, sigs);
        assertTrue(attacker.reentered());
        assertEq(
            attacker.reentryRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(attacker).balance, 1 ether); // paid exactly once
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function test_withdraw_reentrancy_blocksDifferentValidBundle() public {
        // A fully valid, distinct bundle (different id, correctly signed,
        // never used) prepared in advance must still be blocked purely by
        // nonReentrant -- not by the used-id check, since that id was never
        // marked used. This isolates the guard from the replay protection.
        ReentrantReceiver attacker = new ReentrantReceiver();
        bytes32 attestorRole = bridge.ATTESTOR_ROLE();
        // The grant grows the set to 4, so the threshold must rise to 3 first.
        vm.prank(bridgeAdmin);
        bridge.setThreshold(3);
        vm.prank(defaultAdmin);
        bridge.grantRole(attestorRole, address(attacker));

        bytes memory secondId = hex"aabbccddee";
        bytes32 outerDigest = bridge.withdrawalDigest(REQUEST_ID, address(attacker), 1 ether, defaultDeadline);
        bytes[] memory outerSigs = _attestorSignatures(outerDigest, 3);

        bytes32 innerDigest = bridge.withdrawalDigest(secondId, address(attacker), 1 ether, defaultDeadline);
        bytes[] memory innerSigs = _attestorSignatures(innerDigest, 3);

        attacker.arm(IBridgeWithdraw(address(bridge)), secondId, 1 ether, defaultDeadline, innerSigs);

        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, address(attacker), 1 ether, defaultDeadline, outerSigs);

        assertTrue(attacker.reentered());
        assertEq(
            attacker.reentryRevertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertFalse(bridge.isWithdrawRequestUsed(secondId));
        assertEq(address(attacker).balance, 1 ether); // only the outer payout landed

        // Prove the inner bundle was valid all along: absent reentrancy, it
        // pays out normally in a follow-up call.
        vm.prank(attestors[0]);
        bridge.withdraw(secondId, address(attacker), 1 ether, defaultDeadline, innerSigs);
        assertTrue(bridge.isWithdrawRequestUsed(secondId));
        assertEq(address(attacker).balance, 2 ether);
    }

    function test_withdrawLimits_enforced() public {
        // redeploy with a withdraw band and fund it
        BitSafeEvmAssetBridge bounded = _deployBridgeWithWithdrawLimits(1 ether, 10 ether);
        vm.prank(user);
        bounded.depositETH{value: 50 ether}(DEPOSIT_ID);
        bytes32 digest = bounded.withdrawalDigest(REQUEST_ID, destination, 11 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountOutsideLimits.selector, 11 ether, 1 ether, 10 ether)
        );
        vm.prank(attestors[0]);
        bounded.withdraw(REQUEST_ID, destination, 11 ether, defaultDeadline, sigs);
    }

    function test_digest_matchesManualEip712Construction() public view {
        // Independent re-derivation without OZ helpers: the reference vector
        // for the Rust attestor stack.
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BitSafeEvmAssetBridge")),
                keccak256(bytes("1")),
                block.chainid,
                address(bridge)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount,uint256 deadline)"
                ),
                keccak256(REQUEST_ID),
                destination,
                uint256(3 ether),
                defaultDeadline
            )
        );
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
        assertEq(bridge.withdrawalDigest(REQUEST_ID, destination, 3 ether, defaultDeadline), expected);
    }

    function testFuzz_withdraw_transfersBoundedAmounts(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether));
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, amount, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, amount, defaultDeadline, sigs);
        assertEq(destination.balance, amount);
    }

    function test_withdraw_zeroAmount_reverts() public {
        // ZeroAmount is checked before the signature-count check -- an empty
        // signature array must still surface ZeroAmount, not NotEnoughSignatures.
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(BitSafeEvmAssetBridge.ZeroAmount.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 0, defaultDeadline, noSigs);
    }

    function test_withdraw_ethTransferFailure_leavesRequestUnused() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, address(rejecting), 1 ether, defaultDeadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.expectRevert(BitSafeEvmAssetBridge.EthTransferFailed.selector);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, address(rejecting), 1 ether, defaultDeadline, sigs);
        // The failed send must not consume the request id: it must stay retriable.
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function testFuzz_withdraw_signerPermutations(uint8 permSeed) public {
        // The 6 permutations of 3 attestor indices. Signer order does not
        // matter, so every permutation must succeed.
        uint256[3][6] memory perms = [
            [uint256(0), 1, 2],
            [uint256(0), 2, 1],
            [uint256(1), 0, 2],
            [uint256(1), 2, 0],
            [uint256(2), 0, 1],
            [uint256(2), 1, 0]
        ];
        uint256 permIndex = permSeed % 6;
        uint256[3] memory perm = perms[permIndex];

        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, defaultDeadline);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(attestorPks[perm[i]], digest);
        }

        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, defaultDeadline, sigs);
        assertEq(destination.balance, 1 ether);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function _deployBridgeWithWithdrawLimits(uint256 minAmount, uint256 maxAmount)
        internal
        returns (BitSafeEvmAssetBridge)
    {
        BitSafeEvmAssetBridge impl2 = new BitSafeEvmAssetBridge();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                attestors,
                THRESHOLD,
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
                BitSafeEvmAssetBridge.Limits(minAmount, maxAmount)
            )
        );
        return
            BitSafeEvmAssetBridge(
                payable(address(new TransparentUpgradeableProxy(address(impl2), proxyOwner, initData)))
            );
    }
}
