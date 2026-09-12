// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the withdrawal rate limit: a bucket of `capacity` base units
///         that refills over `window` seconds. A capacity of 0 turns the
///         check off.
/// @dev A lowered capacity acts at once, because new settings never reset the
///      bucket's use. A `window` of 0 with a non-zero `capacity` reverts with
///      `InvalidLimits`.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/SetWithdrawRateLimit.s.sol \
///     --sig 'run(uint256,uint256)' 100000000000000000000 86400 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/SetWithdrawRateLimit.s.sol \
///     --sig 'run(uint256,uint256)' 100000000000000000000 86400 --rpc-url $RPC_URL
contract SetWithdrawRateLimit is BridgeManage {
    function action() public pure override returns (string memory) {
        return "setWithdrawRateLimit";
    }

    function encode(uint256 capacity, uint256 window) public pure returns (bytes memory) {
        require(capacity <= type(uint208).max, "capacity exceeds uint208");
        require(window <= type(uint48).max, "window exceeds uint48");
        return abi.encodeCall(BitSafeEvmAssetBridge.setWithdrawRateLimit, (uint208(capacity), uint48(window)));
    }

    function run(uint256 capacity, uint256 window) external {
        _send(encode(capacity, window));
    }
}
