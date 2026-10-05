// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RateLimitTest} from "../RateLimit.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every RateLimitTest case against the HyperEVM variant.
contract RateLimitHyperTest is RateLimitTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
