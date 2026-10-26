// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {console2} from "forge-std/console2.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

/// @notice Schedules a change to the default admin transfer delay.
/// @dev The new delay takes effect only after its own wait period passes.
///      An increase waits up to `defaultAdminDelayIncreaseWait()`. A decrease
///      waits the difference between the old and new delay. This keeps a
///      transfer from speeding up early. The script refuses a delay above
///      `MAX_DELAY`, the same maximum as the timelock delay scripts.
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
        if (newDelay > MAX_DELAY) {
            revert DelayTooLong(newDelay, MAX_DELAY);
        }
        uint256 delay = AccessControlDefaultAdminRulesUpgradeable(target()).defaultAdminDelay();

        // A decrease shortens the wait of every later admin transfer.
        // The script prints one line for it and does not stop.
        if (newDelay < delay) {
            console2.log("DECREASE: current delay (s)", delay, "-> new delay (s)", newDelay);
        }

        _send(encode(newDelay));

        console2.log("current delay (s)", delay);
        console2.log("new delay (s)", newDelay);
    }
}
