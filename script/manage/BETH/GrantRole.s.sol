// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Grants one role to one account. The default admin governs all
///         three grantable roles: BRIDGE_ADMIN, ATTESTOR and SENTRY.
/// @dev Grow the attestor set with raise-then-grant. Raise the threshold
///      first with SetThreshold. Then grant the new attestor. A grant that
///      drops the threshold to half the attestor count or below reverts.
///
/// Direct:
///   forge script script/manage/BETH/GrantRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourSentry \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/GrantRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourSentry --rpc-url $RPC_URL
contract GrantRole is BethManage {
    function action() public pure override returns (string memory) {
        return "grantRole";
    }

    function encode(string memory roleName, address account) public pure returns (bytes memory) {
        return abi.encodeCall(IAccessControl.grantRole, (roleByName(roleName), account));
    }

    function run(string memory roleName, address account) external {
        _send(encode(roleName, account));
    }
}
