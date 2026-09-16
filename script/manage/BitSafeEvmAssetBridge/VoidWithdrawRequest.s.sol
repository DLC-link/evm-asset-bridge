// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Marks a withdraw request id used without paying it. No signed
///         bundle for that id can execute after this call.
/// @dev Void the id before the attestors confirm the matching Canton cancel.
///      The call works during an incident pause. Pause does not block it.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/VoidWithdrawRequest.s.sol \
///     --sig 'run(bytes)' 0x0011deadbeef22 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/VoidWithdrawRequest.s.sol \
///     --sig 'run(bytes)' 0x0011deadbeef22 --rpc-url $RPC_URL
contract VoidWithdrawRequest is BridgeManage {
    function action() public pure override returns (string memory) {
        return "voidWithdrawRequest";
    }

    function encode(bytes memory withdrawRequestId) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.voidWithdrawRequest, (withdrawRequestId));
    }

    function run(bytes calldata withdrawRequestId) external {
        _send(encode(withdrawRequestId));
    }
}
