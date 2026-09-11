// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Resumes deposits and withdrawals.
/// @dev Only the bridge admin may unpause. A sentry cannot reverse its own pause.
///
/// Direct:
///   forge script script/manage/BETH/Unpause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/Unpause.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL
contract Unpause is BethManage {
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
