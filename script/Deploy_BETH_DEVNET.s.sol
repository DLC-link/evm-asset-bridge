// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Deploy_BETH} from "./Deploy_BETH.s.sol";

/// @title Deploy_BETH_DEVNET
/// @notice Deploys the BETH bridge instance whose attestors run against Canton
///         devnet. Only the deployment name differs from `Deploy_BETH`, so the
///         records land in their own files.
contract Deploy_BETH_DEVNET is Deploy_BETH {
    function deploymentName() public pure override returns (string memory) {
        return "BETH_DEVNET";
    }
}
