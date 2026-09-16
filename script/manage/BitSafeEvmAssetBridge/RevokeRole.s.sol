// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Revokes one role from one account. The default admin governs all
///         three grantable roles: BRIDGE_ADMIN, ATTESTOR and SENTRY.
/// @dev The contract lets a revoke drop the attestor count below the
///      threshold. Every withdrawal then halts. An admin lowers the threshold
///      to recover. One remaining attestor blocks that recovery. No value
///      obeys both bounds at a count of 1. Only a grant of more attestors
///      recovers the bridge from that state. Never let the attestor count
///      fall below 2. Lower the threshold before the revoke to prevent the
///      stop.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/RevokeRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xOldSentry \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/RevokeRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xOldSentry --rpc-url $RPC_URL
contract RevokeRole is BridgeManage {
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
