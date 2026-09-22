// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployNextImplementation} from "../../script/manage/upgrade/DeployNextImplementation.s.sol";

/// Fixes the two values that come from the environment in a real run.
contract DummyDeployNext is DeployNextImplementation {
    string private _name;
    string private _what;

    function configure(string memory name, string memory what) external {
        _name = name;
        _what = what;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    /// An empty `what` takes the default, which reads the implementation
    /// record.
    function contractToDeploy() public view override returns (string memory) {
        if (bytes(_what).length > 0) {
            return _what;
        }
        return super.contractToDeploy();
    }
}

contract DeployNextImplementationTest is Test {
    string internal constant COUNTER_V2 = "test/mocks/CounterUpgradeable.sol:CounterV2";

    function _pending(string memory name) internal pure returns (string memory) {
        return string.concat("deployments/.pending/", name, ".31337.json");
    }

    function _record(string memory name, string memory role) internal pure returns (string memory) {
        return string.concat("deployments/", name, ".", role, ".31337.json");
    }

    function _writeImplRecord(string memory name, string memory contractName, string memory sourcePath) internal {
        string memory key = string.concat(name, "impl");
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", contractName);
        vm.serializeString(key, "sourcePath", sourcePath);
        vm.writeJson(vm.serializeAddress(key, "address", address(1)), _record(name, "implementation"));
    }

    function test_run_writesANextImplementationPendingFile() public {
        string memory name = "UPGDEPLOYNEXT";
        DummyDeployNext d = new DummyDeployNext();
        d.configure(name, COUNTER_V2);

        d.run();

        string memory json = vm.readFile(_pending(name));
        string[] memory roles = vm.parseJsonStringArray(json, ".roles");
        assertEq(roles.length, 1);
        assertEq(roles[0], "nextImplementation");
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        assertEq(addresses.length, 1);
        assertTrue(addresses[0].code.length > 0);
        assertEq(vm.parseJsonStringArray(json, ".contractNames")[0], "CounterV2");
        assertEq(vm.parseJsonStringArray(json, ".sourcePaths")[0], "test/mocks/CounterUpgradeable.sol");
        assertEq(vm.parseJsonString(json, ".broadcastScript"), "DeployNextImplementation.s.sol");
        assertEq(vm.parseJsonString(json, ".note"), "next implementation, not yet live");
        assertEq(vm.parseJsonString(json, ".deploymentName"), name);
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        vm.removeFile(_pending(name));
    }

    /// With no CONTRACT, the script deploys the recorded implementation's
    /// contract again. A bare contract name works as well as a path.
    function test_run_defaultsToTheRecordedImplementation() public {
        string memory name = "UPGDEFAULT";
        _writeImplRecord(name, "CounterV1", "test/mocks/CounterUpgradeable.sol");
        DummyDeployNext d = new DummyDeployNext();
        d.configure(name, "");

        d.run();

        string memory json = vm.readFile(_pending(name));
        assertEq(vm.parseJsonStringArray(json, ".contractNames")[0], "CounterV1");
        assertEq(vm.parseJsonStringArray(json, ".sourcePaths")[0], "test/mocks/CounterUpgradeable.sol");
        vm.removeFile(_pending(name));
        vm.removeFile(_record(name, "implementation"));
    }

    function test_run_acceptsABareContractName() public {
        string memory name = "UPGBARE";
        DummyDeployNext d = new DummyDeployNext();
        d.configure(name, "CounterV2");
        d.run();
        string memory json = vm.readFile(_pending(name));
        assertEq(vm.parseJsonStringArray(json, ".contractNames")[0], "CounterV2");
        assertEq(vm.parseJsonStringArray(json, ".sourcePaths")[0], "test/mocks/CounterUpgradeable.sol");
        vm.removeFile(_pending(name));
    }

    function test_run_refusesAConstructorWithArguments() public {
        DummyDeployNext d = new DummyDeployNext();
        d.configure("UPGCTOR", "test/mocks/CounterUpgradeable.sol:CounterWithConstructorArg");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployNextImplementation.ConstructorTakesArguments.selector, "CounterWithConstructorArg", 1
            )
        );
        d.run();
        assertFalse(vm.exists(_pending("UPGCTOR")));
    }

    function test_run_refusesWhenTheNextRecordExists() public {
        string memory name = "UPGEXISTS";
        string memory path = _record(name, "nextImplementation");
        vm.writeJson("{}", path);
        DummyDeployNext d = new DummyDeployNext();
        d.configure(name, COUNTER_V2);
        vm.expectRevert(abi.encodeWithSelector(DeployNextImplementation.NextImplementationExists.selector, path));
        d.run();
        vm.removeFile(path);
    }
}
