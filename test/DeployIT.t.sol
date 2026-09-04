// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployIT} from "../script/DeployIT.s.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";

/// @notice Pins the IT deployment that DLC-link/dlc-attestor-stack consumes.
///         Its compose files and attestor config hardcode the proxy address,
///         the attestor accounts, and the threshold. A change here breaks
///         that repo's integration suite silently.
contract DeployITTest is Test {
    address internal constant EXPECTED_PROXY = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address internal constant ATTESTOR_1 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // mnemonic index 3
    address internal constant ATTESTOR_2 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // index 4
    address internal constant ATTESTOR_3 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; // index 5
    // The attestor suite holds these two keys on purpose, and it asserts
    // that the bridge rejects their signatures. They must never hold the role.
    address internal constant NON_ATTESTOR_7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955; // mnemonic index 7
    address internal constant NON_ATTESTOR_8 = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f; // index 8

    function test_deployIT_registersThreeAttestorsWithThresholdTwo() public {
        new DeployIT().run();

        BitSafeEvmAssetBridge bridge = BitSafeEvmAssetBridge(payable(EXPECTED_PROXY));
        address[] memory attestors = bridge.getAttestors();

        assertEq(attestors.length, 3, "IT bridge must expose exactly 3 attestors");
        assertEq(bridge.threshold(), 2, "IT bridge threshold must be 2");
        assertTrue(bridge.hasRole(bridge.ATTESTOR_ROLE(), ATTESTOR_1), "index 3 must hold ATTESTOR_ROLE");
        assertTrue(bridge.hasRole(bridge.ATTESTOR_ROLE(), ATTESTOR_2), "index 4 must hold ATTESTOR_ROLE");
        assertTrue(bridge.hasRole(bridge.ATTESTOR_ROLE(), ATTESTOR_3), "index 5 must hold ATTESTOR_ROLE");
        assertFalse(bridge.hasRole(bridge.ATTESTOR_ROLE(), NON_ATTESTOR_7), "index 7 must not hold ATTESTOR_ROLE");
        assertFalse(bridge.hasRole(bridge.ATTESTOR_ROLE(), NON_ATTESTOR_8), "index 8 must not hold ATTESTOR_ROLE");
    }
}
