// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DepositTest} from "../Deposit.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";

/// Runs every DepositTest case against the HyperEVM variant.
contract DepositHyperTest is DepositTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
