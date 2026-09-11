// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Rescues bridged-asset balance above `totalLocked`, such as
///         forced-in ETH or direct token transfers.
/// @dev The amount must not exceed the current surplus. Deposited funds stay
///      out of reach.
///
/// Direct:
///   forge script script/manage/BETH/RescueSurplus.s.sol \
///     --sig 'run(address,uint256)' 0xTo 1000000000000000000 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/RescueSurplus.s.sol \
///     --sig 'run(address,uint256)' 0xTo 1000000000000000000 --rpc-url $RPC_URL
contract RescueSurplus is BethManage {
    function action() public pure override returns (string memory) {
        return "rescueSurplus";
    }

    function encode(address to, uint256 amount) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.rescueSurplus, (to, amount));
    }

    function run(address to, uint256 amount) external {
        _send(encode(to, amount));
    }
}
