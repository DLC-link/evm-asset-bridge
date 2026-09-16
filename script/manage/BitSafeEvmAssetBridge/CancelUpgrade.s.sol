// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeManage} from "./UpgradeManage.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Cancels a scheduled upgrade. The timelock accepts the call from a
///         canceller. The proxy owner Safe holds that role.
/// @dev The script derives the operation id from the `nextImplementation`
///      record and from `data`, like the other two scripts. A cancel of an
///      operation that is not pending reverts with
///      `TimelockUnexpectedOperationState`.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/CancelUpgrade.s.sol --sig 'run(bytes)' 0x \
///     --rpc-url $RPC_URL --broadcast --account proxyOwner
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/CancelUpgrade.s.sol \
///     --sig 'run(bytes)' 0x --rpc-url $RPC_URL
contract CancelUpgrade is UpgradeManage {
    function action() public pure override returns (string memory) {
        return "cancelUpgrade";
    }

    /// The implementation of the scheduled upgrade. A test overrides it.
    function nextImplementation() public view virtual returns (address) {
        return recordAddress("nextImplementation");
    }

    function encode(address newImplementation, bytes memory data) public view returns (bytes memory) {
        return abi.encodeCall(TimelockController.cancel, (operationId(newImplementation, data)));
    }

    function run(bytes calldata data) external {
        _send(encode(nextImplementation(), data));
    }
}
