// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Sets the minimum and maximum deposit amount, in asset base units.
///         Both bounds are inclusive.
/// @dev The maximum must stay above 0, and the minimum must stay at or below
///      the maximum. Use `pause` to block traffic, not a zero maximum.
///
/// Direct:
///   forge script script/manage/BETH/SetDepositLimits.s.sol \
///     --sig 'run(uint256,uint256)' 100000000 900000000 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/SetDepositLimits.s.sol \
///     --sig 'run(uint256,uint256)' 100000000 900000000 --rpc-url $RPC_URL
contract SetDepositLimits is BethManage {
    function action() public pure override returns (string memory) {
        return "setDepositLimits";
    }

    function encode(uint256 minAmount, uint256 maxAmount) public pure returns (bytes memory) {
        return abi.encodeCall(
            BitSafeEvmAssetBridge.setDepositLimits,
            (BitSafeEvmAssetBridge.Limits({minAmount: minAmount, maxAmount: maxAmount}))
        );
    }

    function run(uint256 minAmount, uint256 maxAmount) external {
        _send(encode(minAmount, maxAmount));
    }
}
