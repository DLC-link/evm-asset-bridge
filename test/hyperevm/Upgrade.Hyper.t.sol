// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeTest} from "../Upgrade.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every UpgradeTest case against the HyperEVM variant.
contract UpgradeHyperTest is UpgradeTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
