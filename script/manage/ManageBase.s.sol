// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title ManageBase
/// @notice The shared half of every management script. It finds the deployed
///         contract, and it either broadcasts a call or writes a Safe
///         transaction for an admin Safe to sign.
/// @dev Each action script builds its calldata in one pure `encode` function
///      and passes it here. That single builder is what keeps the two modes
///      in step: a Safe signs byte-for-byte what a direct broadcast sends.
abstract contract ManageBase is Script {
    string internal constant SAFE_DIR = "deployments/.safe";

    error RecordChainMismatch(uint256 recordChainId, uint256 chainId);
    error TargetHasNoCode(address target);

    /// The deployment name, such as "BETH". A per-deployment base sets it.
    function deploymentName() public pure virtual returns (string memory);

    /// A short name for this action, such as "pause". It names the envelope
    /// file, and it fills the Safe UI origin field.
    function action() public pure virtual returns (string memory);

    /// The address this action calls. It defaults to the recorded proxy.
    /// A test overrides it, and so does a script that targets another
    /// contract, such as the ProxyAdmin.
    function target() internal view virtual returns (address) {
        return recordAddress("proxy");
    }

    /// The Safe that proposes this action, or the zero address for a direct
    /// broadcast. A test overrides it, because a test must not set an
    /// environment variable.
    function safeAddress() internal view virtual returns (address) {
        return vm.envOr("SAFE", address(0));
    }

    /// Reads one recorded address for the current chain. The record's own
    /// chain id must agree, so a record copied to the wrong file name stops
    /// the run instead of pointing at a foreign contract.
    function recordAddress(string memory role) public view returns (address) {
        string memory path =
            string.concat("deployments/", deploymentName(), ".", role, ".", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        uint256 recordChainId = vm.parseJsonUint(json, ".chainId");
        if (recordChainId != block.chainid) {
            revert RecordChainMismatch(recordChainId, block.chainid);
        }
        return vm.parseJsonAddress(json, ".address");
    }

    function _send(bytes memory data) internal {
        _send(target(), data);
    }

    function _send(address to, bytes memory data) internal {
        address safe = safeAddress();
        if (safe == address(0)) {
            vm.startBroadcast();
            _call(to, data);
            vm.stopBroadcast();
        } else {
            // The prank proves the Safe holds the role and the arguments are
            // valid. It runs before anybody signs, and it costs nothing.
            vm.prank(safe);
            _call(to, data);
            _writeEnvelope(safe, to, data);
        }
    }

    /// Bubbles the target's own revert data, so a role failure reports the
    /// contract's error and not a generic one.
    /// @dev Rejects a target with no code. A low-level call to an empty
    ///      address returns success with no data, which would let a stale
    ///      record or a wrong chain look like a real call that succeeded.
    function _call(address to, bytes memory data) private {
        if (to.code.length == 0) {
            revert TargetHasNoCode(to);
        }
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// Writes the transaction envelope that script/manage/safe/propose.sh
    /// reads. The envelope carries no bridge knowledge, so a later upgrade
    /// script reuses the same proposer.
    function _writeEnvelope(address safe, address to, bytes memory data) private {
        string memory key = "safeTx";
        vm.serializeString(key, "deployment", deploymentName());
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeString(key, "action", action());
        vm.serializeAddress(key, "safe", safe);
        vm.serializeAddress(key, "to", to);
        // A uint256 does not survive a JSON number, so every number that
        // reaches the Safe API travels as a string.
        vm.serializeString(key, "value", "0");
        vm.serializeBytes(key, "data", data);
        string memory out = vm.serializeUint(key, "operation", 0);

        string memory path =
            string.concat(SAFE_DIR, "/", deploymentName(), ".", vm.toString(block.chainid), ".", action(), ".json");
        vm.createDir(SAFE_DIR, true);
        vm.writeJson(out, path);

        console2.log("Safe transaction written to:", path);
        console2.log(out);
    }
}
