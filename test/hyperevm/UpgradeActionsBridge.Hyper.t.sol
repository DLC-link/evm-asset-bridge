// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeActionsBridgeTest} from "../manage/UpgradeActions.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every UpgradeActionsBridgeTest case against the HyperEVM variant.
contract UpgradeActionsBridgeHyperTest is UpgradeActionsBridgeTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }

    function _nameSuffix() internal pure override returns (string memory) {
        return "HYPE";
    }
}
