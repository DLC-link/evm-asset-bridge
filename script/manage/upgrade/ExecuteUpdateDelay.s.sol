// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpdateDelayManage} from "./UpdateDelayManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Executes a scheduled change of the minimum delay after the delay
///         has passed. The timelock accepts the call from an executor. The
///         proxy owner Safe holds that role.
/// @dev The script derives the operation from the live delay and the new
///      delay. It asks the timelock for the live state first.
///      `OperationNotReady` names the seconds left. `OperationNotOnChain`
///      means the schedule never landed, or another delay change ran first;
///      see UpdateDelayManage. `OperationDone` means the change already ran.
///      The logged delay after the call comes from the forge simulation in
///      both modes, not from the chain.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/upgrade/ExecuteUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL --broadcast --account proxyOwner
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/upgrade/ExecuteUpdateDelay.s.sol \
///     --sig 'run(uint256)' 86400 --rpc-url $RPC_URL
contract ExecuteUpdateDelay is UpdateDelayManage {
    function action() public pure override returns (string memory) {
        return "executeUpdateDelay";
    }

    function encode(uint256 newDelay) public view returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.execute, (timelock(), 0, updateDelayCall(newDelay), predecessor(), delaySalt(newDelay))
        );
    }

    function run(uint256 newDelay) external {
        uint256 delay = currentDelay();
        bytes32 id = delayOperationId(newDelay);
        _requireLive(id, true);
        _send(encode(newDelay));

        console2.log("timelock", timelock());
        console2.log("previous delay (s)", delay);
        console2.log("new delay (s)", newDelay);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("delay after the call (s)", currentDelay());
    }
}
