// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeManage} from "./BridgeManage.s.sol";
import {BitSafeEvmAssetBridge} from "../../../src/BitSafeEvmAssetBridge.sol";

/// @notice Rescues tokens sent to the bridge by mistake. This script never
///         moves the bridged asset.
/// @dev The bridge rejects a `token` equal to the configured asset. Use
///      RescueSurplus for a bridged-asset balance above `totalLocked`.
///
/// Direct:
///   DEPLOYMENT=BETH forge script script/manage/BitSafeEvmAssetBridge/RescueERC20.s.sol \
///     --sig 'run(address,address,uint256)' 0xToken 0xTo 100 \
///     --rpc-url $RPC_URL --broadcast --account bridgeAdmin
///
/// Safe:
///   DEPLOYMENT=BETH SAFE=0xYourSafe forge script script/manage/BitSafeEvmAssetBridge/RescueERC20.s.sol \
///     --sig 'run(address,address,uint256)' 0xToken 0xTo 100 --rpc-url $RPC_URL
contract RescueERC20 is BridgeManage {
    function action() public pure override returns (string memory) {
        return "rescueERC20";
    }

    function encode(address token, address to, uint256 amount) public pure returns (bytes memory) {
        return abi.encodeCall(BitSafeEvmAssetBridge.rescueERC20, (token, to, amount));
    }

    function run(address token, address to, uint256 amount) external {
        _send(encode(token, to, amount));
    }
}
