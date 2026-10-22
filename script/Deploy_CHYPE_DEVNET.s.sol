// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Deploy_CHYPE} from "./Deploy_CHYPE.s.sol";

/// @title Deploy_CHYPE_DEVNET
/// @notice Deploys the HYPE bridge instance whose attestors run against Canton
///         devnet. Only the deployment name differs from `Deploy_CHYPE`, so
///         the records land in their own files.
contract Deploy_CHYPE_DEVNET is Deploy_CHYPE {
    function deploymentName() public pure override returns (string memory) {
        return "CHYPE_DEVNET";
    }
}
