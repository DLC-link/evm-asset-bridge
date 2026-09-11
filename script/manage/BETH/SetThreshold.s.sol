// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the number of attestor signatures a withdrawal needs.
/// @dev The new value must stay at `MIN_THRESHOLD` or above. `MIN_THRESHOLD`
///      is 2. The new value must not exceed the attestor count. The new
///      value must also stay above half of the attestor count.
///
///      Grow the attestor set with raise-then-grant. Raise the threshold
///      first with this script. Then grant the new attestor with GrantRole.
///
/// Direct:
///   forge script script/manage/BETH/SetThreshold.s.sol --sig 'run(uint256)' 3 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/SetThreshold.s.sol \
///     --sig 'run(uint256)' 3 --rpc-url $RPC_URL
contract SetThreshold is BethManage {
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
