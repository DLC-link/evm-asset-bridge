// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the withdrawal horizon in seconds. The horizon is the maximum
///         distance a withdrawal deadline can sit past the current time. A
///         horizon of 0 disables the bound.
/// @dev A change invalidates every unsubmitted bundle whose deadline lies
///      past the new bound. The signers must re-sign those requests.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/SetWithdrawalHorizon.s.sol \
///     --sig 'run(uint256)' 172800 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/SetWithdrawalHorizon.s.sol \
///     --sig 'run(uint256)' 172800 --rpc-url $RPC_URL
contract SetWithdrawalHorizon is BridgeManage {
    function action() public pure override returns (string memory) {
        return "setWithdrawalHorizon";
    }

    function encode(uint256 horizon) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.setWithdrawalHorizon, (horizon));
    }

    function run(uint256 horizon) external {
        _send(encode(horizon));
    }
}
