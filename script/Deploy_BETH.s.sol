// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeDeploy} from "./BridgeDeploy.s.sol";

/// @title Deploy_BETH
/// @notice Deploys the production BETH bridge. The part of the file name after
///         the underscore is the deployment name, and `script/record.sh` reads
///         it from the path it invokes.
/// @dev `BridgeDeploy.run` reads every value from the environment. A
///      non-production instance subclasses this contract and overrides
///      `deploymentName` only.
contract Deploy_BETH is BridgeDeploy {
    function deploymentName() public pure virtual override returns (string memory) {
        return "BETH";
    }
}
