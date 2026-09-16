// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the withdrawal horizon in seconds. The horizon is the maximum
///         distance a withdrawal deadline can sit past the current time. A
///         horizon of 0 disables the bound.
/// @dev The attestor stack reads this value to pick its signing mode. A
///      change during signing splits the attestors. The attestors then
///      re-sign on the next signing tick.
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
