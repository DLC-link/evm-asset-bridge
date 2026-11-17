// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeDeploy} from "./BridgeDeploy.s.sol";

/// @notice Deploys the native BNB bridge on BSC mainnet.
contract Deploy_CBNB is BridgeDeploy {
    function deploymentName() public pure override returns (string memory) {
        return "CBNB";
    }
}
