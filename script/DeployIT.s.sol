// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployIT
/// @notice Fixed-ordering deployment of one BitSafeEvmAssetBridge (ETH) for
///         the Docker-based integration-test (IT) stack, run against a local
///         anvil chain. NOT for testnet/mainnet use — see script/Deploy.s.sol
///         for the env-var-driven production deployer.
///
/// @dev Determinism: this script is meant to run exactly once against a
///      *fresh* anvil instance seeded from anvil's default account set,
///      which is derived from the standard, well-known Foundry/Hardhat test
///      mnemonic
///
///          test test test test test test test test test test test junk
///
///      at path m/44'/60'/0'/0/{index}. All seven accounts used below are
///      PUBLIC, well-known test keys — see it/attestor-keys.env. NEVER send
///      real funds to any of them.
///
///      Index assignment (fixed, do not reorder — reordering changes which
///      deterministic nonce produces which contract address):
///        0 = deployer            (broadcasts both CREATEs; also the owner
///                                  of the ProxyAdmin the proxy deploys for
///                                  this IT instance)
///        1 = defaultAdmin        (AccessControlDefaultAdminRules admin)
///        2 = bridgeAdmin         (BRIDGE_ADMIN_ROLE)
///        3 = attestor #1
///        4 = attestor #2
///        5 = attestor #3         (3 attestors, threshold 2)
///        6 = test user           (unused here; reserved for IT scenarios
///                                  that deposit/withdraw as an end user)
///
///      With a fresh chain (deployer nonce 0) this script deploys, in order:
///        nonce 0 -> implementation   = 0x5FbDB2315678afecb367f032d93F642f64180aa3
///        nonce 1 -> proxy (bridge)   = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
///      and the proxy's constructor internally deploys:
///        ProxyAdmin (owner = deployer) = 0xCafac3dD18aC6c6e92c921884f9E4176737C052c
///      These were independently reproduced with `cast compute-address` and
///      are re-asserted by this script after broadcast (see the `require`s
///      below) so a drift in ordering fails loudly instead of silently.
contract DeployIT is Script {
    // ---- Well-known anvil/Hardhat test private keys (PUBLIC, IT-only) ----
    // Derived with: cast wallet derive-private-key
    //   "test test test test test test test test test test test junk" <index>
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // index 0
    uint256 internal constant DEFAULT_ADMIN_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // index 1
    uint256 internal constant BRIDGE_ADMIN_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // index 2
    uint256 internal constant ATTESTOR_1_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6; // index 3
    uint256 internal constant ATTESTOR_2_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a; // index 4
    uint256 internal constant ATTESTOR_3_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba; // index 5
    uint256 internal constant TEST_USER_PK = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e; // index 6

    uint48 internal constant ADMIN_DELAY = 0; // IT: no timelock friction on the default-admin handover
    uint256 internal constant THRESHOLD = 2;
    /// Canton expresses 10 decimal places, so a deposit must be a multiple of 1e8 wei.
    uint8 internal constant CANTON_DECIMALS = 10;

    // Expected addresses on a fresh anvil chain (deployer nonce starts at 0).
    // See the contract-level natspec for how these were derived.
    address internal constant EXPECTED_IMPLEMENTATION = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address internal constant EXPECTED_PROXY = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;

    function run() external {
        address deployer = vm.addr(DEPLOYER_PK);
        address defaultAdmin = vm.addr(DEFAULT_ADMIN_PK);
        address bridgeAdmin = vm.addr(BRIDGE_ADMIN_PK);
        address testUser = vm.addr(TEST_USER_PK);

        address[] memory attestors = new address[](3);
        attestors[0] = vm.addr(ATTESTOR_1_PK);
        attestors[1] = vm.addr(ATTESTOR_2_PK);
        attestors[2] = vm.addr(ATTESTOR_3_PK);

        BitSafeEvmAssetBridge.Limits memory noLimits =
            BitSafeEvmAssetBridge.Limits({minAmount: 0, maxAmount: type(uint256).max});

        require(vm.getNonce(deployer) == 0, "DeployIT: deployer nonce != 0; run only against a fresh anvil");

        vm.startBroadcast(DEPLOYER_PK);
        BitSafeEvmAssetBridge implementation = new BitSafeEvmAssetBridge();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0), // asset = ETH
                CANTON_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                attestors,
                THRESHOLD,
                noLimits, // deposit limits: no minimum, no maximum
                noLimits // withdraw limits: no minimum, no maximum
            )
        );
        // The proxy's constructor deploys its own ProxyAdmin, owned by
        // `deployer` (the second constructor argument), and atomically
        // calls `initialize` via `initData` in the same transaction.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), deployer, initData);
        vm.stopBroadcast();

        require(address(implementation) == EXPECTED_IMPLEMENTATION, "DeployIT: implementation address drifted");
        require(address(proxy) == EXPECTED_PROXY, "DeployIT: proxy address drifted");

        console2.log("== BitSafeEvmAssetBridge IT deployment ==");
        console2.log("deployer / ProxyAdmin owner (0):", deployer);
        console2.log("defaultAdmin (1):               ", defaultAdmin);
        console2.log("bridgeAdmin (2):                ", bridgeAdmin);
        console2.log("attestor1 (3):                  ", attestors[0]);
        console2.log("attestor2 (4):                  ", attestors[1]);
        console2.log("attestor3 (5):                  ", attestors[2]);
        console2.log("testUser (6):                   ", testUser);
        console2.log("implementation:                 ", address(implementation));
        console2.log("proxy (bridge):                 ", address(proxy));
        console2.log("targetDecimals:                 ", CANTON_DECIMALS);
        console2.log("depositUnit (wei):              ", BitSafeEvmAssetBridge(payable(address(proxy))).depositUnit());
    }
}
