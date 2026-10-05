// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeAdminActionsTest} from "../manage/BridgeAdminActions.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every BridgeAdminActionsTest case against the HyperEVM variant.
contract BridgeAdminActionsHyperTest is BridgeAdminActionsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
