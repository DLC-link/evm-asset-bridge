// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {WithdrawalHorizonTest} from "../WithdrawalHorizon.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every WithdrawalHorizonTest case against the HyperEVM variant.
contract WithdrawalHorizonHyperTest is WithdrawalHorizonTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
