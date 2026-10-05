// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";
import {ManageBase} from "../../script/manage/ManageBase.s.sol";
import {Pause} from "../../script/manage/BitSafeEvmAssetBridge/Pause.s.sol";
import {DeployNextImplementation} from "../../script/manage/upgrade/DeployNextImplementation.s.sol";

/// The real Pause script, with the two values that a real run reads from
/// the environment fixed by the test.
contract CHYPEPause is Pause {
    string private _name;
    address private _safe;

    function configure(string memory name, address safe_) external {
        _name = name;
        _safe = safe_;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function safeAddress() internal view override returns (address) {
        return _safe;
    }
}

/// The real DeployNextImplementation script, with a fixed deployment name.
contract CHYPEDeployNext is DeployNextImplementation {
    function deploymentName() public pure override returns (string memory) {
        return "CHYPENEXT";
    }
}

/// Each test function writes its own record files under its own deployment
/// name, and deletes them. Forge runs test functions in parallel.
contract CHYPEScriptsTest is BridgeTestBase {
    string internal constant VARIANT_NAME = "BitSafeHyperEvmAssetBridge";
    string internal constant VARIANT_PATH = "src/BitSafeHyperEvmAssetBridge.sol";

    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }

    function _record(string memory name, string memory role) internal pure returns (string memory) {
        return string.concat("deployments/", name, ".", role, ".31337.json");
    }

    /// Writes only the fields that the scripts read.
    function _writeRecord(
        string memory name,
        string memory role,
        string memory contractName,
        string memory sourcePath,
        address addr
    ) internal {
        string memory key = string.concat(name, role);
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", contractName);
        vm.serializeString(key, "sourcePath", sourcePath);
        vm.writeJson(vm.serializeAddress(key, "address", addr), _record(name, role));
    }

    function test_acceptsContract_acceptsBothBridgesOnly() public {
        CHYPEPause p = new CHYPEPause();
        assertTrue(p.acceptsContract("BitSafeEvmAssetBridge"));
        assertTrue(p.acceptsContract("BitSafeHyperEvmAssetBridge"));
        assertFalse(p.acceptsContract("BitSafeHyperEvmAssetBridgeV2"));
        assertFalse(p.acceptsContract("TransparentUpgradeableProxy"));
        assertFalse(p.acceptsContract(""));
    }

    function test_pause_drivesACHYPEDeployment() public {
        string memory name = "CHYPEPAUSE";
        _writeRecord(name, "implementation", VARIANT_NAME, VARIANT_PATH, address(implementation));
        _writeRecord(name, "proxy", "TransparentUpgradeableProxy", "", address(bridge));
        CHYPEPause p = new CHYPEPause();
        p.configure(name, bridgeAdmin);

        p.run();

        assertTrue(bridge.paused());
        vm.removeFile(string.concat("deployments/.safe/", name, ".31337.pause.json"));
        vm.removeFile(_record(name, "implementation"));
        vm.removeFile(_record(name, "proxy"));
    }

    function test_pause_stillDrivesABaseDeployment() public {
        string memory name = "CHYPEBASE";
        _writeRecord(name, "implementation", "BitSafeEvmAssetBridge", "src/BitSafeEvmAssetBridge.sol", address(1));
        _writeRecord(name, "proxy", "TransparentUpgradeableProxy", "", address(bridge));
        CHYPEPause p = new CHYPEPause();
        p.configure(name, bridgeAdmin);

        p.run();

        assertTrue(bridge.paused());
        vm.removeFile(string.concat("deployments/.safe/", name, ".31337.pause.json"));
        vm.removeFile(_record(name, "implementation"));
        vm.removeFile(_record(name, "proxy"));
    }

    function test_pause_refusesAThirdContract() public {
        string memory name = "CHYPEOTHER";
        _writeRecord(name, "implementation", "SomeOtherContract", "src/SomeOtherContract.sol", address(1));
        CHYPEPause p = new CHYPEPause();
        p.configure(name, bridgeAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(ManageBase.ContractMismatch.selector, "SomeOtherContract", "BitSafeEvmAssetBridge")
        );
        p.run();

        assertFalse(bridge.paused());
        vm.removeFile(_record(name, "implementation"));
    }

    /// With no CONTRACT, the script deploys the recorded contract again. A
    /// CHYPE upgrade therefore keeps the reserved-destination check.
    function test_deployNext_deploysTheVariantForACHYPERecord() public {
        string memory name = "CHYPENEXT";
        _writeRecord(name, "implementation", VARIANT_NAME, VARIANT_PATH, address(implementation));

        new CHYPEDeployNext().run();

        string memory pending = string.concat("deployments/.pending/", name, ".31337.json");
        string memory json = vm.readFile(pending);
        assertEq(vm.parseJsonStringArray(json, ".contractNames")[0], VARIANT_NAME);
        assertEq(vm.parseJsonStringArray(json, ".sourcePaths")[0], VARIANT_PATH);
        address next = vm.parseJsonAddressArray(json, ".addresses")[0];
        assertEq(keccak256(next.code), keccak256(address(new BitSafeHyperEvmAssetBridge()).code));
        assertTrue(keccak256(next.code) != keccak256(address(new BitSafeEvmAssetBridge()).code));
        vm.removeFile(pending);
        vm.removeFile(_record(name, "implementation"));
    }
}
