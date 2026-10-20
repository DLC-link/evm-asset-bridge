// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {console2} from "forge-std/console2.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Prints the live configuration of the recorded bridge. The script
///         sends no transaction. It therefore needs no sender and no
///         broadcast flag.
///
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/Status.s.sol --sig 'run()' --rpc-url $RPC_URL
contract Status is BridgeManage {
    function action() public pure override returns (string memory) {
        return "status";
    }

    function run() external view {
        report(target(), timelockAddress());
    }

    /// Returns the recorded timelock, or zero when the deployment has no
    /// timelock record. Older deployments have no timelock. Status must still
    /// work for them. It reads only the address, never the deploy-time config.
    function timelockAddress() public view returns (address) {
        string memory path =
            string.concat("deployments/", deploymentName(), ".timelock.", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) {
            return address(0);
        }
        return recordAddress("timelock");
    }

    /// The timelock delay comes from the chain. A record can differ from the
    /// live value after an `updateDelay` operation.
    function report(address bridgeAddress, address timelockAddress_) public view {
        BitSafeEvmAssetBridge b = BitSafeEvmAssetBridge(payable(bridgeAddress));
        console2.log("bridge           ", bridgeAddress);
        console2.log("paused           ", b.paused());
        console2.log("asset            ", b.asset());
        console2.log("assetDecimals    ", b.assetDecimals());
        console2.log("targetDecimals   ", b.targetDecimals());
        console2.log("depositUnit      ", b.depositUnit());
        console2.log("threshold        ", b.threshold());
        console2.log("totalLocked      ", b.totalLocked());
        console2.log("surplus          ", b.surplus());
        console2.log("withdrawalHorizon", b.withdrawalHorizon());
        console2.log("defaultAdmin     ", b.defaultAdmin());
        console2.log("defaultAdminDelay", b.defaultAdminDelay());
        if (timelockAddress_ != address(0)) {
            console2.log("timelockMinDelay ", TimelockController(payable(timelockAddress_)).getMinDelay());
        }

        BitSafeEvmAssetBridge.Limits memory d = b.depositLimits();
        console2.log("depositMin       ", d.minAmount);
        console2.log("depositMax       ", d.maxAmount);
        BitSafeEvmAssetBridge.Limits memory w = b.withdrawLimits();
        console2.log("withdrawMin      ", w.minAmount);
        console2.log("withdrawMax      ", w.maxAmount);

        (uint208 capacity, uint48 window, uint256 budget) = b.withdrawRateLimit();
        console2.log("rateLimitCapacity", capacity);
        console2.log("rateLimitWindow  ", window);
        console2.log("rateLimitBudget  ", budget);

        address[] memory attestorList = b.getAttestors();
        console2.log("attestorCount    ", attestorList.length);
        for (uint256 i; i < attestorList.length; ++i) {
            console2.log("  attestor       ", attestorList[i]);
        }

        (address pendingAdmin, uint48 adminSchedule) = b.pendingDefaultAdmin();
        if (pendingAdmin != address(0)) {
            console2.log("pendingAdmin     ", pendingAdmin);
            console2.log("pendingAdminAt   ", adminSchedule);
        }
        (uint48 pendingDelay, uint48 delaySchedule) = b.pendingDefaultAdminDelay();
        if (delaySchedule != 0) {
            console2.log("pendingDelay     ", pendingDelay);
            console2.log("pendingDelayAt   ", delaySchedule);
        }
    }
}
