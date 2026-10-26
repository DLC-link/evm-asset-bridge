// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpdateDelayManage} from "./UpdateDelayManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Cancels a scheduled change of the minimum delay. The timelock
///         accepts the call from a canceller. The proxy owner Safe holds
///         that role.
/// @dev The script derives the operation from the live delay and the new
///      delay. A cancelled operation does not count as done. The operator can
///      then schedule the same change again. `OperationNotOnChain` means the schedule never
///      landed, or another delay change ran first; see UpdateDelayManage.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/CancelUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/CancelUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL
contract CancelUpdateDelay is UpdateDelayManage {
    function action() public pure override returns (string memory) {
        return "cancelUpdateDelay";
    }

    function encode(uint256 newDelay) public view returns (bytes memory) {
        return abi.encodeCall(TimelockController.cancel, (delayOperationId(newDelay)));
    }

    function run(uint256 newDelay) external {
        bytes32 id = delayOperationId(newDelay);
        _requireLive(id, false);
        _send(encode(newDelay));

        console2.log("timelock", timelock());
        console2.log("current delay (s)", currentDelay());
        console2.log("new delay (s)", newDelay);
        console2.log("cancelled operation");
        console2.logBytes32(id);
    }
}
