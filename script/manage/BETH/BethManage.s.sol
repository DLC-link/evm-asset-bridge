// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ManageBase} from "../ManageBase.s.sol";

/// @title BethManage
/// @notice Binds the management base to the BETH deployment records. Every
///         BETH action script extends this contract.
abstract contract BethManage is ManageBase {
    function deploymentName() public pure override returns (string memory) {
        return "BETH";
    }
}
