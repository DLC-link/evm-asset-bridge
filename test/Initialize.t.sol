// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// Proxy constructor reverts bubble the inner error; this alias keeps intent readable.
import {
    TransparentUpgradeableProxy as TransparentUpgradeableProxyHarness
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract InitializeTest is BridgeTestBase {
    function test_initialState() public view {
        assertEq(bridge.asset(), address(0));
        assertEq(bridge.threshold(), THRESHOLD);
        assertEq(bridge.getAttestors().length, 3);
        bytes32 attestorRole = bridge.ATTESTOR_ROLE();
        assertTrue(bridge.hasRole(attestorRole, attestors[0]));
        assertTrue(bridge.hasRole(attestorRole, attestors[1]));
        assertTrue(bridge.hasRole(attestorRole, attestors[2]));
        assertTrue(bridge.hasRole(bridge.BRIDGE_ADMIN_ROLE(), bridgeAdmin));
        assertEq(bridge.defaultAdmin(), defaultAdmin);
    }

    function test_storageLocation_matchesErc7201Formula() public view {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("bitsafe.storage.BitSafeEvmAssetBridge")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(bridge.BRIDGE_STORAGE_LOCATION(), expected);
    }

    function test_reinitialize_reverts() public {
        address[] memory a = attestors;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bridge.initialize(
            address(0),
            DEFAULT_TARGET_DECIMALS,
            defaultAdmin,
            ADMIN_DELAY,
            bridgeAdmin,
            a,
            THRESHOLD,
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
        );
    }

    function test_implementation_isLocked() public {
        address[] memory a = attestors;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(0),
            DEFAULT_TARGET_DECIMALS,
            defaultAdmin,
            ADMIN_DELAY,
            bridgeAdmin,
            a,
            THRESHOLD,
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
        );
    }

    function test_initialize_duplicateAttestor_reverts() public {
        address[] memory dup = new address[](2);
        dup[0] = attestors[0];
        dup[1] = attestors[0];
        BitSafeEvmAssetBridge impl2 = _newImplementation();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                dup,
                2,
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }

    function test_initialize_thresholdBounds_revert() public {
        // threshold 1 < MIN_THRESHOLD
        _expectInitRevert(1, BitSafeEvmAssetBridge.ThresholdOutOfBounds.selector);
        // threshold 4 > 3 attestors
        _expectInitRevert(4, BitSafeEvmAssetBridge.ThresholdOutOfBounds.selector);
    }

    function test_initialize_halfThreshold_passes() public {
        // 2 of 4 passes: MIN_THRESHOLD is the only lower bound.
        uint256[] memory pks = new uint256[](4);
        pks[0] = 0xA11CE1;
        pks[1] = 0xA11CE2;
        pks[2] = 0xA11CE3;
        pks[3] = 0xA11CE4;
        _setAttestorsSortedByAddress(pks);
        BitSafeEvmAssetBridge fourOfWhichTwo = _deployBridgeWithThreshold(2);
        assertEq(fourOfWhichTwo.threshold(), 2);
        assertEq(fourOfWhichTwo.getAttestors().length, 4);
    }

    function test_initialize_threeOfFour_passes() public {
        // 3 of 4 passes.
        uint256[] memory pks = new uint256[](4);
        pks[0] = 0xA11CE1;
        pks[1] = 0xA11CE2;
        pks[2] = 0xA11CE3;
        pks[3] = 0xA11CE4;
        _setAttestorsSortedByAddress(pks);
        BitSafeEvmAssetBridge fourOfWhichThree = _deployBridgeWithThreshold(3);
        assertEq(fourOfWhichThree.threshold(), 3);
        assertEq(fourOfWhichThree.getAttestors().length, 4);
    }

    function test_initialize_twoOfTwo_passes() public {
        // 2 of 2 stays valid: it meets the MIN_THRESHOLD floor.
        uint256[] memory pks = new uint256[](2);
        pks[0] = 0xA11CE1;
        pks[1] = 0xA11CE2;
        _setAttestorsSortedByAddress(pks);
        BitSafeEvmAssetBridge twoOfTwo = _deployBridgeWithThreshold(2);
        assertEq(twoOfTwo.threshold(), 2);
        assertEq(twoOfTwo.getAttestors().length, 2);
    }

    function _deployBridgeWithThreshold(uint256 threshold_) internal returns (BitSafeEvmAssetBridge) {
        BitSafeEvmAssetBridge impl2 = _newImplementation();
        bytes memory initData = _initData(threshold_);
        TransparentUpgradeableProxyHarness proxy =
            new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
        return BitSafeEvmAssetBridge(payable(address(proxy)));
    }

    function _expectInitRevert(uint256 threshold_, bytes4 selector) internal {
        _expectInitRevert(threshold_, abi.encodePacked(selector));
    }

    function _expectInitRevert(uint256 threshold_, bytes memory revertData) internal {
        BitSafeEvmAssetBridge impl2 = _newImplementation();
        bytes memory initData = _initData(threshold_);
        vm.expectRevert(revertData);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }

    function _initData(uint256 threshold_) internal view returns (bytes memory) {
        return abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                attestors,
                threshold_,
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
    }

    function test_initialize_zeroMaxLimit_reverts() public {
        BitSafeEvmAssetBridge impl2 = _newImplementation();
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
                BitSafeEvmAssetBridge.Limits(0, 0),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }

    function test_initialize_zeroAddressAttestor_reverts() public {
        address[] memory withZero = new address[](2);
        withZero[0] = attestors[0];
        withZero[1] = address(0);
        BitSafeEvmAssetBridge impl2 = _newImplementation();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                withZero,
                2,
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }

    function test_initialize_zeroAddressBridgeAdmin_reverts() public {
        BitSafeEvmAssetBridge impl2 = _newImplementation();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                address(0),
                attestors,
                THRESHOLD,
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidAddress.selector);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }

    function test_initialize_depositLimitsMinAboveMax_reverts() public {
        BitSafeEvmAssetBridge impl2 = _newImplementation();
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
                BitSafeEvmAssetBridge.Limits(10 ether, 1 ether),
                BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
            )
        );
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        new TransparentUpgradeableProxyHarness(address(impl2), proxyOwner, initData);
    }
}
