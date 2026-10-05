// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RolesTest} from "../Roles.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every RolesTest case against the HyperEVM variant.
contract RolesHyperTest is RolesTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
