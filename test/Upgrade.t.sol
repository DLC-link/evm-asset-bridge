// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {BridgeV2Mock} from "./mocks/BridgeV2Mock.sol";
import {BitSafeEvmAssetBridgeV1} from "./mocks/BitSafeEvmAssetBridgeV1.sol";
import {ForceSend} from "./mocks/ForceSend.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeTest is BridgeTestBase {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal destination = makeAddr("destination");

    function setUp() public override {
        super.setUp();
        vm.deal(user, 200 ether);
        vm.prank(user);
        bridge.depositETH{value: 100 ether}(DEPOSIT_ID);
    }

    function test_crossInstanceReplay_reverts() public {
        // Same attestor set, second proxy: a bundle for bridge A must fail on bridge B.
        BitSafeEvmAssetBridge bridgeB = _deployBridge(address(0));
        vm.prank(user);
        bridgeB.depositETH{value: 50 ether}(DEPOSIT_ID);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digestA = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digestA, 2);
        // Bridge B hashes a different digest (its own verifyingContract), so
        // the first signature recovers to some other, non-attestor address.
        bytes32 digestB = bridgeB.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        (address recovered,,) = ECDSA.tryRecover(digestB, sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.SignerIsNotAttestor.selector, recovered));
        vm.prank(attestors[0]);
        bridgeB.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_crossChainReplay_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.chainId(11155111); // domain rebuilds with the live chainid
        // The new chain id changes the digest, so the first signature
        // recovers to some other, non-attestor address.
        bytes32 foreignDigest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        (address recovered,,) = ECDSA.tryRecover(foreignDigest, sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.SignerIsNotAttestor.selector, recovered));
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_upgrade_preservesStorageAndDomain() public {
        // consume one id before the upgrade
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);

        // sign a second withdrawal BEFORE the upgrade
        bytes memory secondId = hex"5ec0";
        bytes32 digest2 = bridge.withdrawalDigest(secondId, destination, 2 ether, deadline);
        bytes[] memory sigs2 = _attestorSignatures(digest2, 2);

        // upgrade
        BridgeV2Mock v2 = new BridgeV2Mock();
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(bridge), ADMIN_SLOT)))));
        vm.prank(proxyOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(bridge)), address(v2), "");

        // storage preserved
        assertEq(BridgeV2Mock(payable(address(bridge))).version(), "v2-mock");
        assertEq(bridge.threshold(), THRESHOLD);
        assertEq(bridge.getAttestors().length, 3);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));

        // pre-upgrade signatures stay valid: the domain did not change
        vm.prank(attestors[0]);
        bridge.withdraw(secondId, destination, 2 ether, deadline, sigs2);
        assertEq(destination.balance, 3 ether);
    }

    /// The deployments upgrade in place from the V1 source. The new mapping
    /// comes after every V1 field, so V1 state keeps its values and every
    /// account starts with no link.
    function test_upgradeFromV1_keepsStorage_andStartsLinksAtZero() public {
        BitSafeEvmAssetBridge b = _deployProxy(
            address(new BitSafeEvmAssetBridgeV1()),
            address(0),
            DEFAULT_TARGET_DECIMALS,
            BitSafeEvmAssetBridge.Limits(1 ether, 50 ether),
            BitSafeEvmAssetBridge.Limits(1 ether, 40 ether)
        );

        // V1 state: deposits, a used request id, and every admin setting.
        vm.roll(100);
        vm.prank(user);
        b.depositETH{value: 10 ether}(DEPOSIT_ID);
        vm.startPrank(bridgeAdmin);
        b.setWithdrawRateLimit(30 ether, 1 days);
        b.setWithdrawalHorizon(7 days);
        vm.stopPrank();
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _attestorSignatures(b.withdrawalDigest(REQUEST_ID, destination, 2 ether, deadline), 2);
        vm.prank(attestors[0]);
        b.withdraw(REQUEST_ID, destination, 2 ether, deadline, sigs);

        vm.roll(200);
        BitSafeEvmAssetBridge next = new BitSafeEvmAssetBridge();
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(b), ADMIN_SLOT)))));
        vm.prank(proxyOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(b)), address(next), "");

        assertEq(b.asset(), address(0));
        assertEq(b.assetDecimals(), 18);
        assertEq(b.targetDecimals(), DEFAULT_TARGET_DECIMALS);
        assertEq(b.threshold(), THRESHOLD);
        assertEq(b.getAttestors(), attestors);
        assertEq(b.depositLimits().minAmount, 1 ether);
        assertEq(b.depositLimits().maxAmount, 50 ether);
        assertEq(b.withdrawLimits().minAmount, 1 ether);
        assertEq(b.withdrawLimits().maxAmount, 40 ether);
        (uint208 capacity, uint48 window,) = b.withdrawRateLimit();
        assertEq(capacity, 30 ether);
        assertEq(window, 1 days);
        assertTrue(b.isWithdrawRequestUsed(REQUEST_ID));
        assertEq(b.totalLocked(), 8 ether);
        assertEq(b.withdrawalHorizon(), 7 days);
        assertEq(b.lastDepositBlock(keccak256(DEPOSIT_ID)), 0);

        vm.expectEmit(true, true, false, true, address(b));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 0);
        vm.prank(user);
        b.depositETH{value: 1 ether}(DEPOSIT_ID);
        assertEq(b.lastDepositBlock(keccak256(DEPOSIT_ID)), 200);
        assertEq(b.totalLocked(), 9 ether);
    }

    function test_forcedEth_isInert() public {
        // selfdestruct-forced ETH must not affect any behavior
        ForceSend force = new ForceSend{value: 5 ether}();
        force.boom(payable(address(bridge)));
        assertEq(address(bridge).balance, 105 ether);
        // deposits and withdrawals still work
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }
}
