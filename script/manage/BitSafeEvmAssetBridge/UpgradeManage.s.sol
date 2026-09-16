// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title UpgradeManage
/// @notice The shared half of the three upgrade scripts. Each one talks to the
///         timelock that owns the ProxyAdmin, never to the ProxyAdmin itself.
/// @dev Schedule, execute and cancel must name one operation. Every argument
///      of that operation therefore comes from this one place. A script that
///      built its own salt would schedule an operation that no other script
///      can execute.
abstract contract UpgradeManage is BridgeManage {
    /// The timelock that owns the ProxyAdmin. A test overrides it.
    function timelock() public view virtual returns (address) {
        return recordAddress("timelock");
    }

    /// The ProxyAdmin of the recorded proxy. A test overrides it.
    function proxyAdmin() public view virtual returns (address) {
        return recordAddress("proxyAdmin");
    }

    /// The proxy that receives the upgrade. A test overrides it.
    function proxy() public view virtual returns (address) {
        return recordAddress("proxy");
    }

    /// Every upgrade action calls the timelock. The timelock then calls the
    /// ProxyAdmin, after the delay.
    function target() internal view override returns (address) {
        return timelock();
    }

    /// The call that the timelock forwards to the ProxyAdmin.
    /// @param newImplementation The implementation the proxy points at after the upgrade.
    /// @param data The optional payload for `upgradeAndCall`. Pass `0x` for none.
    function upgradeCall(address newImplementation, bytes memory data) public view returns (bytes memory) {
        return abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(payable(proxy())), newImplementation, data)
        );
    }

    /// The salt binds the operation to one deployment and one implementation.
    /// Two deployments on one chain can share a timelock in the future. The
    /// salt then keeps their operation ids apart.
    function salt(address newImplementation) public view returns (bytes32) {
        return keccak256(abi.encodePacked(deploymentName(), "-upgrade-", newImplementation));
    }

    /// An upgrade depends on no earlier operation.
    function predecessor() public pure returns (bytes32) {
        return bytes32(0);
    }

    /// The id that the timelock stores for this upgrade.
    function operationId(address newImplementation, bytes memory data) public view returns (bytes32) {
        return TimelockController(payable(timelock()))
            .hashOperation(
                proxyAdmin(), 0, upgradeCall(newImplementation, data), predecessor(), salt(newImplementation)
            );
    }
}
