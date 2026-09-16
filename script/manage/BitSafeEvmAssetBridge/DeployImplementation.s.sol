// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DeployBase} from "../../DeployBase.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @title DeployImplementation
/// @notice Deploys the next BitSafeEvmAssetBridge implementation, and registers
///         it under the role `nextImplementation`. The proxy stays on the old
///         implementation until the timelock executes the upgrade.
/// @dev The script extends DeployBase, not ManageBase. It broadcasts a create
///      and it writes a pending file, like a deploy. `make record` then writes
///      `<name>.nextImplementation.<chainId>.json`, and `make verify` verifies
///      it before the upgrade.
///
/// The whole operator sequence, with DEPLOYMENT and RPC_URL exported:
///   1. make manage SCRIPT=DeployImplementation SIG='run()' SIGNER="--account deployer"
///   2. make record
///   3. make verify CHAIN_ID=<chainId>
///   4. make manage SCRIPT=ScheduleUpgrade SIG='run(bytes)' ARGS=0x   (from the proxy owner)
///   5. wait for the timelock delay
///   6. make manage SCRIPT=ExecuteUpgrade SIG='run(bytes)' ARGS=0x    (from the proxy owner)
///   7. make record-upgrade CHAIN_ID=<chainId>
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/DeployImplementation.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account deployer
contract DeployImplementation is DeployBase {
    error DeploymentNotSet();

    /// The operator sets DEPLOYMENT in the environment, like a management
    /// script. A test overrides this function instead.
    function deploymentName() public view virtual override returns (string memory) {
        string memory name = vm.envOr("DEPLOYMENT", string(""));
        if (bytes(name).length == 0) {
            revert DeploymentNotSet();
        }
        return name;
    }

    /// `record.sh` reads the broadcast folder under this file name, because
    /// this script does not live at `script/Deploy_<name>.s.sol`.
    function broadcastScript() public pure override returns (string memory) {
        return "DeployImplementation.s.sol";
    }

    function run() external {
        vm.startBroadcast();
        BitSafeEvmAssetBridge implementation = new BitSafeEvmAssetBridge();
        vm.stopBroadcast();

        _register(
            "nextImplementation", address(implementation), "BitSafeEvmAssetBridge", "src/BitSafeEvmAssetBridge.sol"
        );
        _writePending();
    }

    /// The pending file carries no bridge configuration. One note states
    /// that the proxy does not point at this contract yet.
    function _serializeExtra(string memory jsonKey) internal override returns (string memory) {
        return vm.serializeString(jsonKey, "note", "next implementation, not yet live");
    }
}
