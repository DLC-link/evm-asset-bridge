// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeDeploy} from "./BridgeDeploy.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../src/BitSafeHyperEvmAssetBridge.sol";

/// @title Deploy_CHYPE
/// @notice Deploys the production HYPE bridge on HyperEVM. It deploys
///         BitSafeHyperEvmAssetBridge, which refuses the HyperCore system
///         addresses as a withdraw destination.
/// @dev `BridgeDeploy.run` reads every value from the environment. A
///      non-production instance subclasses this contract and overrides
///      `deploymentName` only.
contract Deploy_CHYPE is BridgeDeploy {
    function deploymentName() public pure virtual override returns (string memory) {
        return "CHYPE";
    }

    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }

    function _implementationName() internal pure override returns (string memory) {
        return "BitSafeHyperEvmAssetBridge";
    }

    function _implementationPath() internal pure override returns (string memory) {
        return "src/BitSafeHyperEvmAssetBridge.sol";
    }
}
