// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DecimalsTest} from "../Decimals.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every DecimalsTest case against the HyperEVM variant.
contract DecimalsHyperTest is DecimalsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
