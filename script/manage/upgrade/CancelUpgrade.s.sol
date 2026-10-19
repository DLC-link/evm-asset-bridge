// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Cancels a scheduled upgrade. The timelock accepts the call from a
///         canceller. The proxy owner Safe holds that role.
/// @dev The script reads the operation id from the `schedule` block. The
///      block stays in the record; `make upgrade-sync` drops it once the
///      chain reports the operation as unset. The nextImplementation record
///      stays too. Delete the file by hand to drop that implementation.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/CancelUpgrade.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/CancelUpgrade.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract CancelUpgrade is UpgradeManage {
    function action() public pure override returns (string memory) {
        return "cancelUpgrade";
    }

    function encode(bytes32 id) public pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.cancel, (id));
    }

    function run() external {
        (Schedule memory s, bool exists) = readSchedule();
        if (!exists) {
            revert NotScheduled(nextRecordPath());
        }
        _requireLive(s.operationId, false);
        _send(encode(s.operationId));
        console2.log("cancelled operation");
        console2.logBytes32(s.operationId);
    }
}
