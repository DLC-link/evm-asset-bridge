// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Completes the transfer of the DEFAULT_ADMIN_ROLE to the caller.
/// @dev The INCOMING admin sends this step, not the current one. The call
///      reverts before the scheduled transfer delay passes. A Safe that is
///      the incoming admin proposes it with SAFE set to that incoming Safe.
///
/// Direct:
///   forge script script/manage/BETH/AcceptDefaultAdminTransfer.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account newDefaultAdmin
///
/// Safe:
///   SAFE=0xYourIncomingSafe forge script script/manage/BETH/AcceptDefaultAdminTransfer.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract AcceptDefaultAdminTransfer is BethManage {
    function action() public pure override returns (string memory) {
        return "acceptDefaultAdminTransfer";
    }

    function encode() public pure returns (bytes memory) {
        return abi.encodeCall(AccessControlDefaultAdminRulesUpgradeable.acceptDefaultAdminTransfer, ());
    }

    function run() external {
        _send(encode());
    }
}
