// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Schedules the upgrade of the proxy to the recorded next
///         implementation. The timelock accepts the call from a proposer.
///         The proxy owner Safe holds that role.
/// @dev `make record` writes the `nextImplementation` record after
///      `DeployImplementation`. This script reads that record, so the
///      operator names no address on the command line. The delay is the
///      timelock's own minimum. A longer delay needs no support here.
///
/// `data` is the optional payload for `upgradeAndCall`. Pass `0x` for none.
/// ExecuteUpgrade must receive the same `data`, because both scripts derive
/// the operation id from it.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/ScheduleUpgrade.s.sol --sig 'run(bytes)' 0x \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/ScheduleUpgrade.s.sol \
///     --sig 'run(bytes)' 0x --rpc-url $RPC_URL
contract ScheduleUpgrade is UpgradeManage {
    function action() public pure override returns (string memory) {
        return "scheduleUpgrade";
    }

    /// The implementation the upgrade installs. A test overrides it.
    function nextImplementation() public view virtual returns (address) {
        return recordAddress("nextImplementation");
    }

    function encode(address newImplementation, bytes memory data) public view returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.schedule,
            (
                proxyAdmin(),
                0,
                upgradeCall(newImplementation, data),
                predecessor(),
                salt(newImplementation),
                TimelockController(payable(timelock())).getMinDelay()
            )
        );
    }

    function run(bytes calldata data) external {
        address newImplementation = nextImplementation();
        uint256 delay = TimelockController(payable(timelock())).getMinDelay();
        console2.log("next implementation", newImplementation);
        console2.logBytes32(operationId(newImplementation, data));
        console2.log("earliest execute at", block.timestamp + delay);
        _send(encode(newImplementation, data));
    }
}
