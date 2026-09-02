// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";

contract DeployTest is Test {
    function test_deployScript_producesWorkingBridgeAndJson() public {
        vm.setEnv("ASSET", "0x0000000000000000000000000000000000000000");
        vm.setEnv("DEFAULT_ADMIN", vm.toString(makeAddr("da")));
        vm.setEnv("ADMIN_DELAY", "172800");
        vm.setEnv("BRIDGE_ADMIN", vm.toString(makeAddr("ba")));
        vm.setEnv("PROXY_OWNER", vm.toString(makeAddr("po")));
        vm.setEnv("ATTESTORS", string.concat(
            vm.toString(makeAddr("a1")), ",", vm.toString(makeAddr("a2")), ",", vm.toString(makeAddr("a3"))));
        vm.setEnv("THRESHOLD", "2");
        vm.setEnv("DEPOSIT_MIN", "0");
        vm.setEnv("DEPOSIT_MAX", vm.toString(type(uint256).max));
        vm.setEnv("WITHDRAW_MIN", "0");
        vm.setEnv("WITHDRAW_MAX", vm.toString(type(uint256).max));

        new Deploy().run();

        string memory path = string.concat(
            "deployments/BitSafeEvmAssetBridge.", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address proxy = vm.parseJsonAddress(json, ".proxy");
        assertEq(BitSafeEvmAssetBridge(payable(proxy)).threshold(), 2);
        assertEq(BitSafeEvmAssetBridge(payable(proxy)).getAttestors().length, 3);
    }
}
