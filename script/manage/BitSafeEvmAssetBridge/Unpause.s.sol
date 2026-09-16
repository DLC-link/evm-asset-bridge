// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Resumes deposits and withdrawals.
/// @dev Only the bridge admin may unpause. A sentry cannot reverse its own pause.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/Unpause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/Unpause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL
contract Unpause is BridgeManage {
    function action() public pure override returns (string memory) {
        return "unpause";
    }

    function encode() public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.unpause, ());
    }

    function run() external {
        _send(encode());
    }
}
