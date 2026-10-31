// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeDeploy} from "./BridgeDeploy.s.sol";

/// @title Deploy_CHYPE
/// @notice Deploys the production HYPE bridge on HyperEVM.
/// @dev `BridgeDeploy.run` reads every value from the environment. A
///      non-production instance subclasses this contract and overrides
///      `deploymentName` only.
contract Deploy_CHYPE is BridgeDeploy {
    function deploymentName() public pure virtual override returns (string memory) {
        return "CHYPE";
    }
}
