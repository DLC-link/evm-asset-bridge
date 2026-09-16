// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Grants one role to one account. The default admin governs all
///         three grantable roles: BRIDGE_ADMIN, ATTESTOR and SENTRY.
/// @dev The contract sets no order rule for a grant. An operator adds an
///      attestor before a threshold change or after it. The contract checks
///      no ratio between the threshold and the attestor count. The team sets
///      that ratio by governance policy.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/GrantRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourSentry \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/GrantRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourSentry --rpc-url $RPC_URL
contract GrantRole is BridgeManage {
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
