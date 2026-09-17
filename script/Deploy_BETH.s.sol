// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeDeploy} from "./BridgeDeploy.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";

/// @title Deploy_BETH
/// @notice Deploys the production BETH bridge. The part of the file name after
///         the underscore is the deployment name, and `script/record.sh` reads
///         it from the path it invokes.
/// @dev Every value comes from the environment. See the README for the table.
///      A non-production instance subclasses this contract and overrides
///      `deploymentName` only. `run` stays the single reader of the
///      environment, so every instance reads the same variables.
contract Deploy_BETH is BridgeDeploy {
    function deploymentName() public pure virtual override returns (string memory) {
        return "BETH";
    }

    function run() external {
        Params memory p;
        p.asset = vm.envAddress("ASSET");
        uint256 targetDecimalsRaw = vm.envUint("TARGET_DECIMALS");
        require(targetDecimalsRaw <= type(uint8).max, "TARGET_DECIMALS out of range");
        p.targetDecimals = uint8(targetDecimalsRaw);
        p.defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        uint256 adminDelayRaw = vm.envUint("ADMIN_DELAY");
        require(adminDelayRaw <= type(uint48).max, "ADMIN_DELAY out of range");
        p.adminDelay = uint48(adminDelayRaw);
        p.bridgeAdmin = vm.envAddress("BRIDGE_ADMIN");
        p.proxyOwner = vm.envAddress("PROXY_OWNER");
        p.timelockDelay = vm.envUint("TIMELOCK_DELAY");
        require(p.timelockDelay >= MIN_TIMELOCK_DELAY, "TIMELOCK_DELAY too low");
        p.attestors = vm.envAddress("ATTESTORS", ",");
        // A bridge with no attestor can release nothing. Foundry stops on an
        // empty ATTESTORS before this line today. The require states the intent
        // and holds if a future Foundry parses a blank value as an empty list.
        require(p.attestors.length > 0, "ATTESTORS is empty");
        p.threshold = vm.envUint("THRESHOLD");
        p.depositLimits = BitSafeEvmAssetBridge.Limits(vm.envUint("DEPOSIT_MIN"), vm.envUint("DEPOSIT_MAX"));
        p.withdrawLimits = BitSafeEvmAssetBridge.Limits(vm.envUint("WITHDRAW_MIN"), vm.envUint("WITHDRAW_MAX"));

        _deployBridge(p);
    }
}
