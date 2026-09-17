// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the number of attestor signatures a withdrawal needs. The
///         default admin holds this action, because the threshold and the
///         attestor set together define how many operators must agree.
/// @dev The contract applies two bounds to the new value. The value must stay
///      at `MIN_THRESHOLD` or above. `MIN_THRESHOLD` is 2. The value must not
///      exceed the attestor count.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol --sig 'run(uint256)' 3 \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol \
///     --sig 'run(uint256)' 3 --rpc-url $RPC_URL
contract SetThreshold is BridgeManage {
    function action() public pure override returns (string memory) {
        return "setThreshold";
    }

    function encode(uint256 newThreshold) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.setThreshold, (newThreshold));
    }

    function run(uint256 newThreshold) external {
        _send(encode(newThreshold));
    }
}
