// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// One struct keeps `run` inside the EVM stack limit.
    struct Config {
        address asset;
        uint8 targetDecimals;
        address defaultAdmin;
        uint48 adminDelay;
        address bridgeAdmin;
        address proxyOwner;
        address[] attestors;
        uint256 threshold;
        BitSafeEvmAssetBridge.Limits depositLimits;
        BitSafeEvmAssetBridge.Limits withdrawLimits;
    }

    function run() external {
        Config memory c = _readConfig();

        vm.startBroadcast();
        BitSafeEvmAssetBridge implementation = new BitSafeEvmAssetBridge();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            c.proxyOwner,
            abi.encodeCall(
                BitSafeEvmAssetBridge.initialize,
                (
                    c.asset,
                    c.targetDecimals,
                    c.defaultAdmin,
                    c.adminDelay,
                    c.bridgeAdmin,
                    c.attestors,
                    c.threshold,
                    c.depositLimits,
                    c.withdrawLimits
                )
            )
        );
        vm.stopBroadcast();

        _writeJson(c, address(proxy), address(implementation));
    }

    function _readConfig() internal view returns (Config memory c) {
        c.asset = vm.envAddress("ASSET");
        uint256 targetDecimalsRaw = vm.envUint("TARGET_DECIMALS");
        require(targetDecimalsRaw <= type(uint8).max, "TARGET_DECIMALS out of range");
        c.targetDecimals = uint8(targetDecimalsRaw);
        c.defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        c.adminDelay = uint48(vm.envUint("ADMIN_DELAY"));
        c.bridgeAdmin = vm.envAddress("BRIDGE_ADMIN");
        c.proxyOwner = vm.envAddress("PROXY_OWNER");
        c.attestors = vm.envAddress("ATTESTORS", ",");
        c.threshold = vm.envUint("THRESHOLD");
        c.depositLimits = BitSafeEvmAssetBridge.Limits(vm.envUint("DEPOSIT_MIN"), vm.envUint("DEPOSIT_MAX"));
        c.withdrawLimits = BitSafeEvmAssetBridge.Limits(vm.envUint("WITHDRAW_MIN"), vm.envUint("WITHDRAW_MAX"));
    }

    function _writeJson(Config memory c, address proxy, address implementation) internal {
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        BitSafeEvmAssetBridge bridge = BitSafeEvmAssetBridge(payable(proxy));

        string memory json = "deployment";
        vm.serializeAddress(json, "proxy", proxy);
        vm.serializeAddress(json, "implementation", implementation);
        vm.serializeAddress(json, "proxyAdmin", proxyAdmin);
        vm.serializeAddress(json, "asset", c.asset);
        // The asset reports its own decimals; the JSON records what the contract read.
        vm.serializeUint(json, "assetDecimals", bridge.assetDecimals());
        vm.serializeUint(json, "targetDecimals", c.targetDecimals);
        vm.serializeUint(json, "depositUnit", bridge.depositUnit());
        vm.serializeAddress(json, "defaultAdmin", c.defaultAdmin);
        vm.serializeUint(json, "adminDelay", c.adminDelay);
        vm.serializeAddress(json, "bridgeAdmin", c.bridgeAdmin);
        vm.serializeAddress(json, "attestors", c.attestors);
        vm.serializeUint(json, "threshold", c.threshold);
        vm.serializeUint(json, "depositMin", c.depositLimits.minAmount);
        vm.serializeUint(json, "depositMax", c.depositLimits.maxAmount);
        vm.serializeUint(json, "withdrawMin", c.withdrawLimits.minAmount);
        vm.serializeUint(json, "withdrawMax", c.withdrawLimits.maxAmount);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeString(json, "compiler", "0.8.34");
        string memory out = vm.serializeString(json, "gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        vm.writeJson(out, string.concat("deployments/BitSafeEvmAssetBridge.", vm.toString(block.chainid), ".json"));
    }
}
