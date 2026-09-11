// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the withdrawal horizon: the maximum distance a withdrawal
///         deadline can sit past the current time, in seconds. 0 disables it.
/// @dev The attestor stack reads this value to pick its signing mode. A
///      change mid-signing splits attestors; they re-sign on the next tick.
///
/// Direct:
///   forge script script/manage/BETH/SetWithdrawalHorizon.s.sol \
///     --sig 'run(uint256)' 172800 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/SetWithdrawalHorizon.s.sol \
///     --sig 'run(uint256)' 172800 --rpc-url $RPC_URL
contract SetWithdrawalHorizon is BethManage {
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
