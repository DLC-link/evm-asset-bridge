// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DeployBase} from "../../DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployNextImplementation
/// @notice Deploys the next implementation of a recorded deployment and
///         registers it under the role `nextImplementation`. The proxy stays
///         on the old implementation until the timelock executes the upgrade.
/// @dev The script extends DeployBase, not ManageBase. It broadcasts a create
///      and writes a pending file, like a deploy. `make record` then writes
///      `<name>.nextImplementation.<chainId>.json`, and `make verify`
///      verifies it before the upgrade. The script knows no contract. It
///      deploys the artifact that CONTRACT names, or the recorded
///      implementation's contract by default.
///
///      It refuses a contract whose constructor takes arguments. Every
///      implementation this repo deploys has a constructor that only disables
///      the initializers. This is a deliberate heuristic. It loosens to an
///      optional constructor-arguments parameter if we need one.
///
///   DEPLOYMENT=BETH forge script script/manage/upgrade/DeployNextImplementation.s.sol --sig 'run()' \
///     --rpc-url $RPC_URL --broadcast --account deployer
contract DeployNextImplementation is DeployBase {
    error DeploymentNotSet();
    error NextImplementationExists(string path);
    error ConstructorTakesArguments(string contractName, uint256 inputs);

    /// The operator sets DEPLOYMENT in the environment, like a management
    /// script. A test overrides this function instead.
    function deploymentName() public view virtual override returns (string memory) {
        string memory name = vm.envOr("DEPLOYMENT", string(""));
        if (bytes(name).length == 0) {
            revert DeploymentNotSet();
        }
        return name;
    }

    /// forge names the broadcast folder after this file, and `record.sh`
    /// reads that folder.
    function broadcastScript() public pure override returns (string memory) {
        return "DeployNextImplementation.s.sol";
    }

    /// The artifact to deploy, as `<sourcePath>:<ContractName>` or a bare
    /// contract name. CONTRACT in the environment overrides the default,
    /// which is the recorded implementation's contract. A test overrides it.
    function contractToDeploy() public view virtual returns (string memory) {
        string memory fromEnv = vm.envOr("CONTRACT", string(""));
        if (bytes(fromEnv).length > 0) {
            return fromEnv;
        }
        string memory record = vm.readFile(recordPath("implementation"));
        return
            string.concat(vm.parseJsonString(record, ".sourcePath"), ":", vm.parseJsonString(record, ".contractName"));
    }

    function recordPath(string memory role) public view returns (string memory) {
        return string.concat("deployments/", deploymentName(), ".", role, ".", vm.toString(block.chainid), ".json");
    }

    function run() external {
        string memory nextPath = recordPath("nextImplementation");
        if (vm.exists(nextPath)) {
            revert NextImplementationExists(nextPath);
        }

        string memory what = contractToDeploy();
        string memory artifact = vm.readFile(vm.getArtifactPathByCode(vm.getCode(what)));
        // compilationTarget holds one key: the source path.
        string memory sourcePath = vm.parseJsonKeys(artifact, ".metadata.settings.compilationTarget")[0];
        string memory name = _nameOf(what);
        uint256 inputs = _constructorInputs(artifact);
        if (inputs > 0) {
            revert ConstructorTakesArguments(name, inputs);
        }

        vm.startBroadcast();
        address next = deployCode(what);
        vm.stopBroadcast();

        _register("nextImplementation", next, name, sourcePath);
        _writePending();

        console2.log("next implementation", next);
        console2.log("contract", string.concat(sourcePath, ":", name));
        console2.log("next steps: make record, then make verify");
    }

    /// The pending file carries no configuration. One note states that the
    /// proxy does not point at this contract yet.
    function _serializeExtra(string memory jsonKey) internal override returns (string memory) {
        return vm.serializeString(jsonKey, "note", "next implementation, not yet live");
    }

    /// The part after the last `:`, or the whole string for a bare name.
    function _nameOf(string memory what) internal pure returns (string memory) {
        bytes memory b = bytes(what);
        uint256 start;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ":") {
                start = i + 1;
            }
        }
        bytes memory out = new bytes(b.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /// Counts the inputs of the ABI's constructor entry. Zero when the ABI
    /// has no constructor.
    function _constructorInputs(string memory artifact) internal view returns (uint256) {
        for (uint256 i; vm.keyExistsJson(artifact, string.concat(".abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            string memory kind = vm.parseJsonString(artifact, string.concat(entry, ".type"));
            if (keccak256(bytes(kind)) != keccak256(bytes("constructor"))) {
                continue;
            }
            uint256 n;
            while (vm.keyExistsJson(artifact, string.concat(entry, ".inputs[", vm.toString(n), "]"))) {
                ++n;
            }
            return n;
        }
        return 0;
    }
}
