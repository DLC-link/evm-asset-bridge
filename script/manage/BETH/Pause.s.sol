// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Pauses deposits and withdrawals.
/// @dev The bridge admin and a sentry may both call it. This script names no
///      role, so either sender works.
///
/// Direct:
///   forge script script/manage/BETH/Pause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account sentry
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/Pause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL
contract Pause is BethManage {
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
