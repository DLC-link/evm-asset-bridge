// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {BridgeV2Mock} from "./mocks/BridgeV2Mock.sol";
import {ForceSend} from "./mocks/ForceSend.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
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
        vm.expectRevert(); // digest differs on B, recovered signers are not attestors
        vm.prank(attestors[0]);
        bridgeB.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
    }

    function test_crossChainReplay_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.chainId(11155111); // domain rebuilds with the live chainid
        vm.expectRevert();
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
