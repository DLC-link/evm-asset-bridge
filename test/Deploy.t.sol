// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deploy_BETH} from "../script/Deploy_BETH.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";

contract DeployTest is Test {
    /// Forge runs test functions in parallel, and `vm.setEnv` writes process
    /// state that every test shares. Only one test here may touch the
    /// environment, so this one covers the happy path and both range guards.
    function test_deployScript_writesPendingFileAndRejectsOutOfRangeEnv() public {
        _setValidEnv();

        new Deploy_BETH().run();

        string memory path = string.concat("deployments/.pending/BETH.", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        // The three roles appear in a fixed order. script/record.sh relies on it.
        string[] memory roles = vm.parseJsonStringArray(json, ".roles");
        assertEq(roles.length, 3);
        assertEq(roles[0], "implementation");
        assertEq(roles[1], "proxy");
        assertEq(roles[2], "proxyAdmin");

        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        assertEq(addresses.length, 3);

        // The proxy is live and initialized.
        BitSafeEvmAssetBridge bridge = BitSafeEvmAssetBridge(payable(addresses[1]));
        assertEq(bridge.threshold(), 2);
        assertEq(bridge.getAttestors().length, 3);

        // The ProxyAdmin address comes from the EIP-1967 admin slot.
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        assertEq(addresses[2], address(uint160(uint256(vm.load(addresses[1], adminSlot)))));

        // The record carries what the old thin file never held.
        assertEq(vm.parseJsonString(json, ".deploymentName"), "BETH");
        assertEq(vm.parseJsonAddress(json, ".proxyOwner"), makeAddr("po"));
        assertEq(vm.parseJsonUint(json, ".threshold"), 2);

        // The three decimals values come back from the deployed contract.
        assertEq(vm.parseJsonUint(json, ".assetDecimals"), 18);
        assertEq(vm.parseJsonUint(json, ".targetDecimals"), 10);
        assertEq(vm.parseJsonUint(json, ".depositUnit"), 1e8);

        // A value the script narrows must fail loudly when it does not fit.
        // A silent truncation would deploy a bridge that nobody configured.
        _setValidEnv();
        vm.setEnv("TARGET_DECIMALS", vm.toString(uint256(type(uint8).max) + 1));
        Deploy_BETH wideDecimals = new Deploy_BETH();
        vm.expectRevert(bytes("TARGET_DECIMALS out of range"));
        wideDecimals.run();

        _setValidEnv();
        vm.setEnv("ADMIN_DELAY", vm.toString(uint256(type(uint48).max) + 1));
        Deploy_BETH wideDelay = new Deploy_BETH();
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
