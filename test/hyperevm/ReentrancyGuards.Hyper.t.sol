// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuardsTest} from "../ReentrancyGuards.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every ReentrancyGuardsTest case against the HyperEVM variant.
contract ReentrancyGuardsHyperTest is ReentrancyGuardsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
