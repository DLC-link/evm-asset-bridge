// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InitializeTest} from "../Initialize.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every InitializeTest case against the HyperEVM variant.
contract InitializeHyperTest is InitializeTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
