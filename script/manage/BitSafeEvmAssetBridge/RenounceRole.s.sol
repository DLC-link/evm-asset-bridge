// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Drops one of the caller's own roles. The caller must pass its own
///         address as `account`.
/// @dev The attestor role rejects a renounce. An attestor leaves only
///      through RevokeRole, called by the default admin.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/RenounceRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourOwnAddress \
///     --rpc-url $RPC_URL --broadcast --account sentry
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/RenounceRole.s.sol \
///     --sig 'run(string,address)' SENTRY 0xYourSafe --rpc-url $RPC_URL
contract RenounceRole is BridgeManage {
    function action() public pure override returns (string memory) {
        return "renounceRole";
    }

    function encode(string memory roleName, address account) public pure returns (bytes memory) {
        return abi.encodeCall(IAccessControl.renounceRole, (roleByName(roleName), account));
    }

    function run(string memory roleName, address account) external {
        _send(encode(roleName, account));
    }
}
