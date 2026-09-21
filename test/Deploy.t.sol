// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deploy_BETH} from "../script/Deploy_BETH.s.sol";
import {Deploy_BETH_DEVNET} from "../script/Deploy_BETH_DEVNET.s.sol";
import {Deploy_BETH_TESTNET} from "../script/Deploy_BETH_TESTNET.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployTest is Test {
    /// Forge runs test functions in parallel, and `vm.setEnv` writes process
    /// state that every test shares. Only one test here may touch the
    /// environment, so this one covers the happy path and both range guards.
    function test_deployScript_writesPendingFileAndRejectsOutOfRangeEnv() public {
        _setValidEnv();

        new Deploy_BETH().run();

        string memory path = string.concat("deployments/.pending/BETH.", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        // A deploy at the default path names no broadcast script.
        assertFalse(vm.keyExistsJson(json, ".broadcastScript"));

        // The four roles appear in a fixed order. script/record.sh relies on it.
        string[] memory roles = vm.parseJsonStringArray(json, ".roles");
        assertEq(roles.length, 4);
        assertEq(roles[0], "implementation");
        assertEq(roles[1], "timelock");
        assertEq(roles[2], "proxy");
        assertEq(roles[3], "proxyAdmin");

        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        assertEq(addresses.length, 4);

        // The proxy is live and initialized.
        BitSafeEvmAssetBridge bridge = BitSafeEvmAssetBridge(payable(addresses[2]));
        assertEq(bridge.threshold(), 2);
        assertEq(bridge.getAttestors().length, 3);

        // The ProxyAdmin address comes from the EIP-1967 admin slot.
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        assertEq(addresses[3], address(uint160(uint256(vm.load(addresses[2], adminSlot)))));

        // The timelock owns the ProxyAdmin. An upgrade therefore waits the delay.
        assertEq(Ownable(addresses[3]).owner(), addresses[1]);

        // The proxy owner drives the timelock. The timelock administers itself,
        // so a role or delay change also waits the delay.
        TimelockController timelock = TimelockController(payable(addresses[1]));
        address proxyOwner = makeAddr("po");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proxyOwner));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), proxyOwner));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proxyOwner));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), addresses[1]));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proxyOwner));
        assertEq(timelock.getMinDelay(), 3600);

        _upgradeOnlyThroughTheTimelock(timelock, addresses[3], addresses[2], proxyOwner);

        // The record carries what the old thin file never held.
        assertEq(vm.parseJsonString(json, ".deploymentName"), "BETH");
        assertEq(vm.parseJsonAddress(json, ".proxyOwner"), proxyOwner);
        assertEq(vm.parseJsonAddress(json, ".timelock"), addresses[1]);
        assertEq(vm.parseJsonUint(json, ".timelockDelay"), 3600);
        assertEq(vm.parseJsonUint(json, ".threshold"), 2);

        // The three decimals values come back from the deployed contract.
        assertEq(vm.parseJsonUint(json, ".assetDecimals"), 18);
        assertEq(vm.parseJsonUint(json, ".targetDecimals"), 10);
        assertEq(vm.parseJsonUint(json, ".depositUnit"), 1e8);

        // `forge test` shares the pending folder with a real deploy. A file left
        // here would make `make record` find two matches and refuse to guess.
        vm.removeFile(path);

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

        // A short timelock delay removes the review window this deploy promises.
        // A zero delay would let one Safe schedule and execute in one block.
        _setValidEnv();
        vm.setEnv("TIMELOCK_DELAY", "59");
        Deploy_BETH shortTimelock = new Deploy_BETH();
        vm.expectRevert(bytes("TIMELOCK_DELAY too low"));
        shortTimelock.run();

        // Each Sepolia instance carries its own name. Two instances with one
        // name would write the same record files.
        assertEq(new Deploy_BETH_DEVNET().deploymentName(), "BETH_DEVNET");
        assertEq(new Deploy_BETH_TESTNET().deploymentName(), "BETH_TESTNET");

        // The name reaches the pending file, so `make record` writes the
        // records under it.
        _setValidEnv();
        new Deploy_BETH_TESTNET().run();
        string memory testnetPath =
            string.concat("deployments/.pending/BETH_TESTNET.", vm.toString(block.chainid), ".json");
        assertTrue(vm.exists(testnetPath));
        assertEq(vm.parseJsonString(vm.readFile(testnetPath), ".deploymentName"), "BETH_TESTNET");
        vm.removeFile(testnetPath);

        // A bridge with no attestor can release nothing. The deploy must stop.
        _setValidEnv();
        vm.setEnv("ATTESTORS", "");
        Deploy_BETH_TESTNET noAttestors = new Deploy_BETH_TESTNET();
        vm.expectRevert();
        noAttestors.run();
    }

    /// Proves the property the timelock adds. The proxy owner cannot upgrade
    /// through the ProxyAdmin directly. A scheduled upgrade cannot execute
    /// before the delay, and it does execute after it.
    function _upgradeOnlyThroughTheTimelock(
        TimelockController timelock,
        address proxyAdmin,
        address proxy,
        address proxyOwner
    ) internal {
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address before = address(uint160(uint256(vm.load(proxy, implSlot))));
        BitSafeEvmAssetBridge next = new BitSafeEvmAssetBridge();
        bytes memory upgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(payable(proxy)), address(next), "")
        );

        // The direct path is closed: only the timelock owns the ProxyAdmin.
        vm.prank(proxyOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, proxyOwner));
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), address(next), "");

        bytes32 salt = keccak256("upgrade");
        uint256 delay = timelock.getMinDelay();
        vm.prank(proxyOwner);
        timelock.schedule(proxyAdmin, 0, upgrade, bytes32(0), salt, delay);

        // One second before the delay ends, the operation is not ready.
        vm.warp(block.timestamp + delay - 1);
        vm.prank(proxyOwner);
        vm.expectRevert();
        timelock.execute(proxyAdmin, 0, upgrade, bytes32(0), salt);
        assertEq(address(uint160(uint256(vm.load(proxy, implSlot)))), before);

        vm.warp(block.timestamp + 1);
        vm.prank(proxyOwner);
        timelock.execute(proxyAdmin, 0, upgrade, bytes32(0), salt);
        assertEq(address(uint160(uint256(vm.load(proxy, implSlot)))), address(next));
    }

    function _setValidEnv() internal {
        vm.setEnv("ASSET", "0x0000000000000000000000000000000000000000");
        vm.setEnv("TARGET_DECIMALS", "10");
        vm.setEnv("DEFAULT_ADMIN", vm.toString(makeAddr("da")));
        vm.setEnv("ADMIN_DELAY", "172800");
        vm.setEnv("BRIDGE_ADMIN", vm.toString(makeAddr("ba")));
        vm.setEnv("PROXY_OWNER", vm.toString(makeAddr("po")));
        vm.setEnv("TIMELOCK_DELAY", "3600");
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
