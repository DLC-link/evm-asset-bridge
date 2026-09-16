// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Executes a scheduled upgrade after the delay has passed. The
///         timelock accepts the call from an executor. The proxy owner Safe
///         holds that role.
/// @dev The script reads the same `nextImplementation` record as
///      ScheduleUpgrade, and it takes the same `data`. Both scripts then
///      derive one operation id.
///
///      The timelock reverts with `TimelockUnexpectedOperationState(id,
///      0x...04)` while the delay runs. Bit 2 of the second argument names
///      the Ready state. The Safe-mode simulation reports that revert before
///      anybody signs. Wait for the earliest execute time, then run again.
///
///      Run `make record-upgrade` after the transaction lands. It promotes the
///      next-implementation record.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/ExecuteUpgrade.s.sol --sig 'run(bytes)' 0x \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/ExecuteUpgrade.s.sol \
///     --sig 'run(bytes)' 0x --rpc-url $RPC_URL
contract ExecuteUpgrade is UpgradeManage {
    function action() public pure override returns (string memory) {
        return "executeUpgrade";
    }

    /// The implementation the upgrade installs. A test overrides it.
    function nextImplementation() public view virtual returns (address) {
        return recordAddress("nextImplementation");
    }

    function encode(address newImplementation, bytes memory data) public view returns (bytes memory) {
        return abi.encodeCall(
            TimelockController.execute,
            (proxyAdmin(), 0, upgradeCall(newImplementation, data), predecessor(), salt(newImplementation))
        );
    }

    function run(bytes calldata data) external {
        _send(encode(nextImplementation(), data));
    }
}
