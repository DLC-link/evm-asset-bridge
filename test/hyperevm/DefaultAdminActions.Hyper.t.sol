// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DefaultAdminActionsTest} from "../manage/DefaultAdminActions.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every DefaultAdminActionsTest case against the HyperEVM variant.
contract DefaultAdminActionsHyperTest is DefaultAdminActionsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
