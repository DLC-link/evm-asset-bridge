// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Cancels a pending DEFAULT_ADMIN_ROLE transfer.
/// @dev The current default admin sends this step. It clears the pending
///      admin and schedule. The incoming admin can no longer accept.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/CancelDefaultAdminTransfer.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe \
///     forge script script/manage/BitSafeEvmAssetBridge/CancelDefaultAdminTransfer.s.sol \
///     --sig 'run()' --rpc-url $RPC_URL
contract CancelDefaultAdminTransfer is BridgeManage {
    function action() public pure override returns (string memory) {
        return "cancelDefaultAdminTransfer";
    }

    function encode() public pure returns (bytes memory) {
        return abi.encodeCall(AccessControlDefaultAdminRulesUpgradeable.cancelDefaultAdminTransfer, ());
    }

    function run() external {
        _send(encode());
    }
}
