// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BethManage} from "./BethManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Rescues stray ETH, such as ETH forced in via selfdestruct.
/// @dev The bridge rejects this call when the bridged asset is ETH. Use
///      RescueSurplus for a stray ETH balance on an ETH bridge.
///
/// Direct:
///   forge script script/manage/BETH/RescueETH.s.sol \
///     --sig 'run(address,uint256)' 0xTo 1000000000000000000 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   SAFE=0xYourSafe forge script script/manage/BETH/RescueETH.s.sol \
///     --sig 'run(address,uint256)' 0xTo 1000000000000000000 --rpc-url $RPC_URL
contract RescueETH is BethManage {
    function action() public pure override returns (string memory) {
        return "rescueETH";
    }

    function encode(address to, uint256 amount) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.rescueETH, (to, amount));
    }

    function run(address to, uint256 amount) external {
        _send(encode(to, amount));
    }
}
