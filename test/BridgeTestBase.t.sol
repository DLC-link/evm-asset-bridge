// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract BridgeTestBase is Test {
    BitSafeEvmAssetBridge internal bridge;
    BitSafeEvmAssetBridge internal implementation;

    address internal defaultAdmin = makeAddr("defaultAdmin");
    address internal bridgeAdmin = makeAddr("bridgeAdmin");
    address internal proxyOwner = makeAddr("proxyOwner");
    address internal user = makeAddr("user");

    // Attestor private keys. vm.addr derives the addresses; sorting them by
    // address is just a fixture convenience for deterministic ordering in
    // tests -- the contract itself does not require any particular signer
    // order.
    uint256[] internal attestorPks;
    address[] internal attestors;

    uint48 internal constant ADMIN_DELAY = 2 days;
    uint8 internal constant DEFAULT_TARGET_DECIMALS = 10; // Canton, so the deposit unit is 1e8 wei
    uint256 internal constant DEFAULT_DEPOSIT_UNIT = 1e8; // 10 ** (18 - 10), for an ETH bridge
    uint256 internal constant THRESHOLD = 2;
    bytes internal constant DEPOSIT_ID = hex"00a1b2c3d4";
    bytes internal constant REQUEST_ID = hex"0011deadbeef22";

    function setUp() public virtual {
        uint256[] memory pks = new uint256[](3);
        pks[0] = 0xA11CE1;
        pks[1] = 0xA11CE2;
        pks[2] = 0xA11CE3;
        _setAttestorsSortedByAddress(pks);
        bridge = _deployBridge(address(0)); // ETH instance by default
    }

    function _setAttestorsSortedByAddress(uint256[] memory pks) internal {
        // insertion sort by derived address
        for (uint256 i = 1; i < pks.length; ++i) {
            uint256 key = pks[i];
            uint256 j = i;
            while (j > 0 && vm.addr(pks[j - 1]) > vm.addr(key)) {
                pks[j] = pks[j - 1];
                --j;
            }
            pks[j] = key;
        }
        delete attestorPks;
        delete attestors;
        for (uint256 i; i < pks.length; ++i) {
            attestorPks.push(pks[i]);
            attestors.push(vm.addr(pks[i]));
        }
    }

    /// Every fixture runs the shipped precision, so the granularity check is live
    /// across the whole suite. An ETH bridge therefore demands multiples of 1e8.
    function _deployBridge(address asset) internal returns (BitSafeEvmAssetBridge) {
        return _deployBridge(asset, DEFAULT_TARGET_DECIMALS);
    }

    function _deployBridge(address asset, uint8 targetDecimals_) internal returns (BitSafeEvmAssetBridge) {
        return _deployBridgeWith(
            asset,
            targetDecimals_,
            BitSafeEvmAssetBridge.Limits({minAmount: 0, maxAmount: type(uint256).max}),
            BitSafeEvmAssetBridge.Limits({minAmount: 0, maxAmount: type(uint256).max})
        );
    }

    function _deployBridgeWith(
        address asset,
        uint8 targetDecimals_,
        BitSafeEvmAssetBridge.Limits memory depositLimits_,
        BitSafeEvmAssetBridge.Limits memory withdrawLimits_
    ) internal returns (BitSafeEvmAssetBridge) {
        implementation = new BitSafeEvmAssetBridge();
        return _deployProxy(address(implementation), asset, targetDecimals_, depositLimits_, withdrawLimits_);
    }

    /// Deploys a proxy in front of `impl`. The upgrade tests pass an older
    /// implementation, which takes the same `initialize` arguments.
    function _deployProxy(
        address impl,
        address asset,
        uint8 targetDecimals_,
        BitSafeEvmAssetBridge.Limits memory depositLimits_,
        BitSafeEvmAssetBridge.Limits memory withdrawLimits_
    ) internal returns (BitSafeEvmAssetBridge) {
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                asset,
                targetDecimals_,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                attestors,
                THRESHOLD,
                depositLimits_,
                withdrawLimits_
            )
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(impl, proxyOwner, initData);
        return BitSafeEvmAssetBridge(payable(address(proxy)));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Signatures from the first `count` attestors, ordered by signer address.
    function _attestorSignatures(bytes32 digest, uint256 count) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            sigs[i] = _sign(attestorPks[i], digest);
        }
    }
}
