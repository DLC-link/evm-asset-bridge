// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Starts the two-step transfer of the DEFAULT_ADMIN_ROLE to
///         `newAdmin`.
/// @dev The current default admin sends this step. The new admin becomes
///      active only after the configured delay passes. It must also call
///      AcceptDefaultAdminTransfer itself.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/BeginDefaultAdminTransfer.s.sol \
///     --sig 'run(address)' 0xNewAdmin \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/BeginDefaultAdminTransfer.s.sol \
///     --sig 'run(address)' 0xNewAdmin --rpc-url $RPC_URL
contract BeginDefaultAdminTransfer is BridgeManage {
    function action() public pure override returns (string memory) {
        return "beginDefaultAdminTransfer";
    }

    function encode(address newAdmin) public pure returns (bytes memory) {
        return abi.encodeCall(AccessControlDefaultAdminRulesUpgradeable.beginDefaultAdminTransfer, (newAdmin));
    }

    function run(address newAdmin) external {
        _send(encode(newAdmin));
    }
}
