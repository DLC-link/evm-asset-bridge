// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";

/// Upgrade target for tests: adds one function, changes nothing else.
contract BridgeV2Mock is BitSafeEvmAssetBridge {
    function version() external pure returns (string memory) {
        return "v2-mock";
    }
}
