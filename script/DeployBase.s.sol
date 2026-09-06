// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";

/// @title DeployBase
/// @notice Collects the contracts a deployment creates, then writes one flat
///         pending file for `script/record.sh` to finish.
/// @dev The pending file holds four index-aligned arrays instead of an array of
///      objects. Solidity serializes a string array well and nests objects
///      badly, so the flat shape keeps the writer simple. `record.sh` zips the
///      arrays back together with jq.
abstract contract DeployBase is Script {
    string internal constant PENDING_DIR = "deployments/.pending";

    string[] private _roles;
    address[] private _addresses;
    string[] private _contractNames;
    string[] private _sourcePaths;

    /// The name of this deployment, such as "BETH". A concrete script sets it.
    function deploymentName() public pure virtual returns (string memory);

    /// Records one deployed contract under a role label.
    function _register(string memory role, address addr, string memory contractName, string memory sourcePath)
        internal
    {
        _roles.push(role);
        _addresses.push(addr);
        _contractNames.push(contractName);
        _sourcePaths.push(sourcePath);
    }

    /// A subclass adds its own flat fields here. It must serialize onto
    /// `jsonKey` and return the result of its LAST serialize call.
    function _serializeExtra(string memory jsonKey) internal virtual returns (string memory);

    /// Writes the pending file. Call it after every `_register`.
    function _writePending() internal {
        string memory jsonKey = "pending";
        vm.serializeString(jsonKey, "deploymentName", deploymentName());
        vm.serializeUint(jsonKey, "chainId", block.chainid);

        string[] memory roles = _roles;
        address[] memory addresses = _addresses;
        string[] memory contractNames = _contractNames;
        string[] memory sourcePaths = _sourcePaths;

        vm.serializeString(jsonKey, "roles", roles);
        vm.serializeAddress(jsonKey, "addresses", addresses);
        vm.serializeString(jsonKey, "contractNames", contractNames);
        vm.serializeString(jsonKey, "sourcePaths", sourcePaths);

        string memory out = _serializeExtra(jsonKey);

        vm.createDir(PENDING_DIR, true);
        vm.writeJson(out, string.concat(PENDING_DIR, "/", deploymentName(), ".", vm.toString(block.chainid), ".json"));
    }
}
