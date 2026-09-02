// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external {
        address asset = vm.envAddress("ASSET");
        address defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        uint48 adminDelay = uint48(vm.envUint("ADMIN_DELAY"));
        address bridgeAdmin = vm.envAddress("BRIDGE_ADMIN");
        address proxyOwner = vm.envAddress("PROXY_OWNER");
        address[] memory attestors = vm.envAddress("ATTESTORS", ",");
        uint256 threshold = vm.envUint("THRESHOLD");
        BitSafeEvmAssetBridge.Limits memory dep = BitSafeEvmAssetBridge.Limits(
            vm.envUint("DEPOSIT_MIN"), vm.envUint("DEPOSIT_MAX"));
        BitSafeEvmAssetBridge.Limits memory wit = BitSafeEvmAssetBridge.Limits(
            vm.envUint("WITHDRAW_MIN"), vm.envUint("WITHDRAW_MAX"));

        vm.startBroadcast();
        BitSafeEvmAssetBridge implementation = new BitSafeEvmAssetBridge();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyOwner,
            abi.encodeCall(BitSafeEvmAssetBridge.initialize,
                (asset, defaultAdmin, adminDelay, bridgeAdmin, attestors, threshold, dep, wit))
        );
        vm.stopBroadcast();

        address proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));

        string memory json = "deployment";
        vm.serializeAddress(json, "proxy", address(proxy));
        vm.serializeAddress(json, "implementation", address(implementation));
        vm.serializeAddress(json, "proxyAdmin", proxyAdmin);
        vm.serializeAddress(json, "asset", asset);
        vm.serializeAddress(json, "defaultAdmin", defaultAdmin);
        vm.serializeUint(json, "adminDelay", adminDelay);
        vm.serializeAddress(json, "bridgeAdmin", bridgeAdmin);
        vm.serializeAddress(json, "attestors", attestors);
        vm.serializeUint(json, "threshold", threshold);
        vm.serializeUint(json, "depositMin", dep.minAmount);
        vm.serializeUint(json, "depositMax", dep.maxAmount);
        vm.serializeUint(json, "withdrawMin", wit.minAmount);
        vm.serializeUint(json, "withdrawMax", wit.maxAmount);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeString(json, "compiler", "0.8.34");
        string memory out = vm.serializeString(json, "gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        vm.writeJson(out, string.concat(
            "deployments/BitSafeEvmAssetBridge.", vm.toString(block.chainid), ".json"));
    }
}
