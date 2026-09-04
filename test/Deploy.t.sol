// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";

contract DeployTest is Test {
    /// Forge runs test functions in parallel, and `vm.setEnv` writes process
    /// state that every test shares. Only one test here may touch the
    /// environment, so this one covers the happy path and both range guards.
    function test_deployScript_deploysAndRejectsOutOfRangeEnv() public {
        _setValidEnv();

        new Deploy().run();

        string memory path = string.concat("deployments/BitSafeEvmAssetBridge.", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address proxy = vm.parseJsonAddress(json, ".proxy");
        assertEq(BitSafeEvmAssetBridge(payable(proxy)).threshold(), 2);
        assertEq(BitSafeEvmAssetBridge(payable(proxy)).getAttestors().length, 3);
        assertEq(vm.parseJsonString(json, ".compiler"), "0.8.34");
        assertEq(vm.parseJsonString(json, ".gitCommit"), "unknown");
        assertEq(vm.parseJsonUint(json, ".assetDecimals"), 18);
        assertEq(vm.parseJsonUint(json, ".targetDecimals"), 10);
        assertEq(vm.parseJsonUint(json, ".depositUnit"), 1e8);

        // A value the script narrows must fail loudly when it does not fit.
        // A silent truncation would deploy a bridge that nobody configured.
        _setValidEnv();
        vm.setEnv("TARGET_DECIMALS", vm.toString(uint256(type(uint8).max) + 1));
        Deploy wideDecimals = new Deploy();
        vm.expectRevert(bytes("TARGET_DECIMALS out of range"));
        wideDecimals.run();

        _setValidEnv();
        vm.setEnv("ADMIN_DELAY", vm.toString(uint256(type(uint48).max) + 1));
        Deploy wideDelay = new Deploy();
        vm.expectRevert(bytes("ADMIN_DELAY out of range"));
        wideDelay.run();
    }

    function _setValidEnv() internal {
        vm.setEnv("ASSET", "0x0000000000000000000000000000000000000000");
        vm.setEnv("TARGET_DECIMALS", "10");
        vm.setEnv("DEFAULT_ADMIN", vm.toString(makeAddr("da")));
        vm.setEnv("ADMIN_DELAY", "172800");
        vm.setEnv("BRIDGE_ADMIN", vm.toString(makeAddr("ba")));
        vm.setEnv("PROXY_OWNER", vm.toString(makeAddr("po")));
        vm.setEnv(
            "ATTESTORS",
            string.concat(
                vm.toString(makeAddr("a1")), ",", vm.toString(makeAddr("a2")), ",", vm.toString(makeAddr("a3"))
            )
        );
        vm.setEnv("THRESHOLD", "2");
        vm.setEnv("DEPOSIT_MIN", "0");
        vm.setEnv("DEPOSIT_MAX", vm.toString(type(uint256).max));
        vm.setEnv("WITHDRAW_MIN", "0");
        vm.setEnv("WITHDRAW_MAX", vm.toString(type(uint256).max));
    }
}
