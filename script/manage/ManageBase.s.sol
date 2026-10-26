// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title ManageBase
/// @notice The shared half of every management script. It finds the deployed
///         contract, and it either broadcasts a call or writes a Safe
///         transaction for an admin Safe to sign.
/// @dev Each action script builds its calldata in one pure `encode` function
///      and passes it here. That single builder is what keeps the two modes
///      in step: a Safe signs byte-for-byte what a direct broadcast sends.
abstract contract ManageBase is Script {
    string internal constant SAFE_DIR = "deployments/.safe";

    /// A typo with extra zeros sets a delay that later changes must wait
    /// for. Both delay scripts therefore refuse a value above 7 days.
    uint256 internal constant MAX_DELAY = 7 days;

    error RecordChainMismatch(uint256 recordChainId, uint256 chainId);
    error TargetHasNoCode(address target);
    error DeploymentNotSet();
    error ContractMismatch(string recordContractName, string expectedContractName);
    error DelayTooLong(uint256 newDelay, uint256 maximum);

    /// The deployment name, such as "BETH". The operator sets DEPLOYMENT in
    /// the environment. A test overrides this function instead, because a
    /// test must not write a process-global environment variable.
    /// @dev A `pure` override stays legal here. Solidity accepts an override
    ///      that makes the state mutability stricter.
    function deploymentName() public view virtual returns (string memory) {
        return _requireName(vm.envOr("DEPLOYMENT", string("")));
    }

    /// Rejects an empty deployment name. The check is `pure`, so a test
    /// reaches it with no environment variable and no file.
    function _requireName(string memory name) internal pure returns (string memory) {
        if (bytes(name).length == 0) {
            revert DeploymentNotSet();
        }
        return name;
    }

    /// A short name for this action, such as "pause". It names the envelope
    /// file, and it fills the Safe UI origin field.
    function action() public pure virtual returns (string memory);

    /// The contract that this script folder drives. The deployment record
    /// must name the same contract. A per-contract base sets it.
    function contractName() public pure virtual returns (string memory);

    /// A generic script drives whatever contract the record names. It
    /// returns `true` here, and the contract guard then skips its name
    /// comparison. Every per-contract folder keeps the default.
    function acceptsAnyContract() public pure virtual returns (bool) {
        return false;
    }

    /// The address this action calls. It defaults to the recorded proxy.
    /// A test overrides it, and so does a script that targets another
    /// contract, such as the ProxyAdmin.
    function target() internal view virtual returns (address) {
        return recordAddress("proxy");
    }

    /// Checks that the deployment is an instance of this script's contract.
    /// A folder names a contract, and DEPLOYMENT names an instance. An
    /// operator can pair the two wrongly, and this check stops that run.
    /// @dev The proxy record names TransparentUpgradeableProxy, so the check
    ///      reads the implementation record instead.
    function _requireContract() private view {
        if (acceptsAnyContract()) {
            return;
        }
        string memory path =
            string.concat("deployments/", deploymentName(), ".implementation.", vm.toString(block.chainid), ".json");
        string memory recorded = vm.parseJsonString(vm.readFile(path), ".contractName");
        string memory expected = contractName();
        if (keccak256(bytes(recorded)) != keccak256(bytes(expected))) {
            revert ContractMismatch(recorded, expected);
        }
    }

    /// The Safe that proposes this action, or the zero address for a direct
    /// broadcast. A test overrides it, because a test must not set an
    /// environment variable.
    function safeAddress() internal view virtual returns (address) {
        return vm.envOr("SAFE", address(0));
    }

    /// Reads one recorded address for the current chain. The record's own
    /// chain id must agree, so a record copied to the wrong file name stops
    /// the run instead of pointing at a foreign contract.
    function recordAddress(string memory role) public view returns (address) {
        string memory path =
            string.concat("deployments/", deploymentName(), ".", role, ".", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        uint256 recordChainId = vm.parseJsonUint(json, ".chainId");
        if (recordChainId != block.chainid) {
            revert RecordChainMismatch(recordChainId, block.chainid);
        }
        return vm.parseJsonAddress(json, ".address");
    }

    /// @dev Both entry points check the deployment first. The check therefore
    ///      reports a wrong pairing before a missing proxy record hides it.
    function _send(bytes memory data) internal {
        _requireContract();
        _dispatch(target(), data);
    }

    /// Sends to an explicit address. A script that drives another contract of
    /// the same deployment, such as the ProxyAdmin, uses this form.
    function _send(address to, bytes memory data) internal {
        _requireContract();
        _dispatch(to, data);
    }

    function _dispatch(address to, bytes memory data) private {
        address safe = safeAddress();
        if (safe == address(0)) {
            vm.startBroadcast();
            _call(to, data);
            vm.stopBroadcast();
        } else {
            // The prank proves the Safe holds the role and the arguments are
            // valid. It runs before anybody signs, and it costs nothing.
            vm.prank(safe);
            _call(to, data);
            _writeEnvelope(safe, to, data);
        }
    }

    /// Bubbles the target's own revert data, so a role failure reports the
    /// contract's error and not a generic one.
    /// @dev Rejects a target with no code. A low-level call to an empty
    ///      address returns success with no data. A stale record or a wrong
    ///      chain would then report a false success.
    function _call(address to, bytes memory data) private {
        if (to.code.length == 0) {
            revert TargetHasNoCode(to);
        }
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// Writes the transaction envelope that script/manage/safe/propose.sh
    /// reads. The envelope carries no bridge knowledge, so a later upgrade
    /// script reuses the same proposer.
    function _writeEnvelope(address safe, address to, bytes memory data) private {
        string memory key = "safeTx";
        vm.serializeString(key, "deployment", deploymentName());
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeString(key, "action", action());
        vm.serializeAddress(key, "safe", safe);
        vm.serializeAddress(key, "to", to);
        // A uint256 does not survive a JSON number, so every number that
        // reaches the Safe API travels as a string.
        vm.serializeString(key, "value", "0");
        vm.serializeBytes(key, "data", data);
        string memory out = vm.serializeUint(key, "operation", 0);

        string memory path =
            string.concat(SAFE_DIR, "/", deploymentName(), ".", vm.toString(block.chainid), ".", action(), ".json");
        vm.createDir(SAFE_DIR, true);
        vm.writeJson(out, path);

        console2.log("Safe transaction written to:", path);
        console2.log(out);
    }
}
