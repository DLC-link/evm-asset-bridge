// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Pauses deposits and withdrawals.
/// @dev The bridge admin and a sentry may both call it. This script names no
///      role, so either sender works.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/Pause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account sentry
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/Pause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL
contract Pause is BridgeManage {
    function action() public pure override returns (string memory) {
        return "pause";
    }

    function encode() public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.pause, ());
    }

    function run() external {
        _send(encode());
    }
}
