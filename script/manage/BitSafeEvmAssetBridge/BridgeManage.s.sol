// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ManageBase} from "../ManageBase.s.sol";

/// @title BridgeManage
/// @notice Binds the management base to BitSafeEvmAssetBridge. Every action
///         script for this contract extends it.
/// @dev This file names no deployment. The folder names the contract, and
///      the DEPLOYMENT environment variable names one instance of it. A
///      second deployment therefore needs no new Solidity file.
abstract contract BridgeManage is ManageBase {
    function contractName() public pure override returns (string memory) {
        return "BitSafeEvmAssetBridge";
    }

    /// Maps a role name to its hash. A name is safer than a raw bytes32.
    /// A mistyped hash names a role nobody holds. The grant then succeeds
    /// silently, with no effect.
    /// @dev Solidity refuses a qualified constant read on a contract type
    ///      here. This restates the three role hashes as literals instead.
    ///      They must match BitSafeEvmAssetBridge exactly. The test in
    ///      DefaultAdminActions.t.sol checks them against the live contract.
    function roleByName(string memory name) public pure returns (bytes32) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("BRIDGE_ADMIN")) return keccak256("BRIDGE_ADMIN_ROLE");
        if (h == keccak256("ATTESTOR")) return keccak256("ATTESTOR_ROLE");
        if (h == keccak256("SENTRY")) return keccak256("SENTRY_ROLE");
        // AccessControlDefaultAdminRules rejects a direct grant of its own
        // role. BeginDefaultAdminTransfer is the only route for that role.
        require(h != keccak256("DEFAULT_ADMIN"), "use BeginDefaultAdminTransfer for DEFAULT_ADMIN");
        revert("unknown role name");
    }
}
