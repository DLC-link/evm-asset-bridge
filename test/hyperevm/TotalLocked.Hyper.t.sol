// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TotalLockedTest} from "../TotalLocked.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every TotalLockedTest case against the HyperEVM variant.
contract TotalLockedHyperTest is TotalLockedTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
