// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Cancels a pending default admin transfer delay change.
/// @dev The current default admin sends this step. It clears the pending
///      delay and schedule. The current delay stays in effect.
///
/// Direct:
///   forge script script/manage/BETH/RollbackDefaultAdminDelay.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/RollbackDefaultAdminDelay.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract RollbackDefaultAdminDelay is BethManage {
    function action() public pure override returns (string memory) {
        return "rollbackDefaultAdminDelay";
    }

    function encode() public pure returns (bytes memory) {
        return abi.encodeCall(AccessControlDefaultAdminRulesUpgradeable.rollbackDefaultAdminDelay, ());
    }

    function run() external {
        _send(encode());
    }
}
