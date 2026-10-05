// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VoidWithdrawRequestTest} from "../VoidWithdrawRequest.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every VoidWithdrawRequestTest case against the HyperEVM variant.
contract VoidWithdrawRequestHyperTest is VoidWithdrawRequestTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
