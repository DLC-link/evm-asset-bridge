// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {WithdrawTest} from "../Withdraw.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every WithdrawTest case against the HyperEVM variant.
contract WithdrawHyperTest is WithdrawTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
