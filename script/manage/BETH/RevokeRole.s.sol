// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Revokes one role from one account. The default admin governs all
///         three grantable roles: BRIDGE_ADMIN, ATTESTOR and SENTRY.
/// @dev A revoke that drops the attestor count below the threshold blocks
///      every later withdrawal. Lower the threshold first.
///
/// Direct:
///   forge script script/manage/BETH/RevokeRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xOldSentry \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/RevokeRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xOldSentry --rpc-url $RPC_URL
contract RevokeRole is BethManage {
    function action() public pure override returns (string memory) {
        return "revokeRole";
    }

    function encode(string memory roleName, address account) public pure returns (bytes memory) {
        return abi.encodeCall(IAccessControl.revokeRole, (roleByName(roleName), account));
    }

    function run(string memory roleName, address account) external {
        _send(encode(roleName, account));
    }
}
