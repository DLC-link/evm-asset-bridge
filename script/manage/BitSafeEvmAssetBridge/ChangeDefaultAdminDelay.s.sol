// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Schedules a change to the default admin transfer delay.
/// @dev The new delay takes effect only after its own wait period passes.
///      An increase waits up to `defaultAdminDelayIncreaseWait()`. A decrease
///      waits the difference between the old and new delay. This keeps a
///      transfer from speeding up early.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/ChangeDefaultAdminDelay.s.sol \
///     --sig 'run(uint256)' 259200 \
///     --rpc-url $RPC_URL --broadcast --account defaultAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/ChangeDefaultAdminDelay.s.sol \
///     --sig 'run(uint256)' 259200 --rpc-url $RPC_URL
contract ChangeDefaultAdminDelay is BridgeManage {
    function action() public pure override returns (string memory) {
        return "changeDefaultAdminDelay";
    }

    function encode(uint256 newDelay) public pure returns (bytes memory) {
        require(newDelay <= type(uint48).max, "delay exceeds uint48");
        return abi.encodeCall(AccessControlDefaultAdminRulesUpgradeable.changeDefaultAdminDelay, (uint48(newDelay)));
    }

    function run(uint256 newDelay) external {
        _send(encode(newDelay));
    }
}
