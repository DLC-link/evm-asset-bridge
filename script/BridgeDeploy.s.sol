// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DeployBase} from "./DeployBase.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title BridgeDeploy
/// @notice Deploys one BitSafeEvmAssetBridge behind a TransparentUpgradeableProxy,
///         places a TimelockController between the proxy owner and the
///         ProxyAdmin, and registers the four contracts the deploy creates.
/// @dev The proxy's constructor creates its own ProxyAdmin, so the ProxyAdmin
///      has no transaction of its own. This script reads its address from the
///      EIP-1967 admin slot after the broadcast.
abstract contract BridgeDeploy is DeployBase {
    /// The EIP-1967 admin slot: keccak256("eip1967.proxy.admin") - 1.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string internal constant OZ_TRANSPARENT_DIR = "lib/openzeppelin-contracts/contracts/proxy/transparent/";
    string internal constant OZ_TIMELOCK_PATH =
        "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

    /// One struct keeps `run` inside the EVM stack limit. The ninth
    /// initialize parameter already pushed the old script past it.
    struct Params {
        address asset;
        uint8 targetDecimals;
        address defaultAdmin;
        uint48 adminDelay;
        address bridgeAdmin;
        address proxyOwner;
        uint256 timelockDelay;
        address[] attestors;
        uint256 threshold;
        BitSafeEvmAssetBridge.Limits depositLimits;
        BitSafeEvmAssetBridge.Limits withdrawLimits;
    }

    Params internal params;
    address internal deployedProxy;
    address internal deployedTimelock;

    function _deployBridge(Params memory p) internal {
        vm.startBroadcast();
        BitSafeEvmAssetBridge implementation = new BitSafeEvmAssetBridge();
        TimelockController timelock = _deployTimelock(p.timelockDelay, p.proxyOwner);
        // The timelock, not the Safe, owns the ProxyAdmin. An upgrade therefore
        // waits the public delay before it can execute.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(timelock),
            abi.encodeCall(
                BitSafeEvmAssetBridge.initialize,
                (
                    p.asset,
                    p.targetDecimals,
                    p.defaultAdmin,
                    p.adminDelay,
                    p.bridgeAdmin,
                    p.attestors,
                    p.threshold,
                    p.depositLimits,
                    p.withdrawLimits
                )
            )
        );
        vm.stopBroadcast();

        address proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));

        // The order is fixed. record.sh and test/Deploy.t.sol both rely on it.
        _register("implementation", address(implementation), "BitSafeEvmAssetBridge", "src/BitSafeEvmAssetBridge.sol");
        _register("timelock", address(timelock), "TimelockController", OZ_TIMELOCK_PATH);
        _register(
            "proxy",
            address(proxy),
            "TransparentUpgradeableProxy",
            string.concat(OZ_TRANSPARENT_DIR, "TransparentUpgradeableProxy.sol")
        );
        _register("proxyAdmin", proxyAdmin, "ProxyAdmin", string.concat(OZ_TRANSPARENT_DIR, "ProxyAdmin.sol"));

        params = p;
        deployedProxy = address(proxy);
        deployedTimelock = address(timelock);
        _writePending();
    }

    /// The proxy owner proposes, cancels, and executes. OZ grants the canceller
    /// role to every proposer. The zero admin makes the timelock its own admin,
    /// so a role or delay change also waits the delay.
    function _deployTimelock(uint256 delay, address proxyOwner) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = proxyOwner;
        address[] memory executors = new address[](1);
        executors[0] = proxyOwner;
        return new TimelockController(delay, proposers, executors, address(0));
    }

    /// Writes the bridge configuration into the pending file.
    function _serializeExtra(string memory jsonKey) internal override returns (string memory) {
        Params memory p = params;
        BitSafeEvmAssetBridge bridge = BitSafeEvmAssetBridge(payable(deployedProxy));

        vm.serializeAddress(jsonKey, "asset", p.asset);
        // The asset reports its own decimals; the record keeps what the contract read.
        vm.serializeUint(jsonKey, "assetDecimals", bridge.assetDecimals());
        vm.serializeUint(jsonKey, "targetDecimals", bridge.targetDecimals());
        vm.serializeUint(jsonKey, "depositUnit", bridge.depositUnit());
        vm.serializeAddress(jsonKey, "defaultAdmin", p.defaultAdmin);
        vm.serializeUint(jsonKey, "adminDelay", p.adminDelay);
        vm.serializeAddress(jsonKey, "bridgeAdmin", p.bridgeAdmin);
        vm.serializeAddress(jsonKey, "proxyOwner", p.proxyOwner);
        vm.serializeAddress(jsonKey, "timelock", deployedTimelock);
        vm.serializeUint(jsonKey, "timelockDelay", p.timelockDelay);
        vm.serializeAddress(jsonKey, "attestors", p.attestors);
        vm.serializeUint(jsonKey, "threshold", p.threshold);
        vm.serializeUint(jsonKey, "depositMin", p.depositLimits.minAmount);
        vm.serializeUint(jsonKey, "depositMax", p.depositLimits.maxAmount);
        vm.serializeUint(jsonKey, "withdrawMin", p.withdrawLimits.minAmount);
        return vm.serializeUint(jsonKey, "withdrawMax", p.withdrawLimits.maxAmount);
    }
}
