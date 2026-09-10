// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";

/// Shared fixture for the halmos symbolic suite.
///
/// Halmos runs every `check_` function and treats each parameter as a
/// symbolic value: one variable that stands for every possible value of
/// its type. A passing check is a proof over all inputs, within the
/// bounds each test states. forge ignores `check_` functions, so the
/// two suites never collide.
///
/// Fixture bounds shared by every test here: the ETH instance, three
/// attestors, threshold 2, deposit unit 1e8 wei, rate limit off,
/// horizon 0. Request ids are 32 bytes (symbolic content, fixed length:
/// symbolic execution needs a concrete calldata length).
abstract contract SymbolicBase is BridgeTestBase {
    /// Concrete payout target with no code, so an ETH release to it succeeds.
    address internal constant RECEIVER = address(0xCAFE);
    /// The bridge's starting balance in withdraw tests. A funding bound, not a property.
    uint256 internal constant FUND = 1_000_000 ether;
    /// A key outside the attestor set: vm.addr(OUTSIDER_KEY) holds no role.
    uint256 internal constant OUTSIDER_KEY = 0xBAD;

    /// The base fixture sorts the attestors by address, but halmos
    /// models vm.addr as a symbolic address, so each sort comparison
    /// forks setUp into one path per ordering — and halmos demands one
    /// setUp path. The contract accepts any signer order, so this
    /// fixture keeps the keys in their given order instead.
    function setUp() public virtual override {
        uint256[] memory pks = new uint256[](3);
        pks[0] = 0xA11CE1;
        pks[1] = 0xA11CE2;
        pks[2] = 0xA11CE3;
        for (uint256 i; i < pks.length; ++i) {
            attestorPks.push(pks[i]);
            attestors.push(vm.addr(pks[i]));
        }
        bridge = _deployBridge(address(0));

        // The model leaves every vm.addr address unconstrained, so the
        // solver may alias one with a deployed contract — for example
        // the proxy's admin, which the transparent proxy dispatches
        // away from the bridge logic. Real key-derived addresses
        // collide with nothing; these assumptions state that.
        address proxyAdmin = address(uint160(uint256(vm.load(address(bridge), ERC1967_ADMIN_SLOT))));
        for (uint256 i; i < attestors.length; ++i) {
            _assumeFreshAddress(attestors[i], proxyAdmin);
        }
        _assumeFreshAddress(bridgeAdmin, proxyAdmin);
        // user funds the deposits with vm.deal, so an alias with the
        // bridge would let the deal overwrite the bridge's balance.
        _assumeFreshAddress(user, proxyAdmin);
        _assumeFreshAddress(defaultAdmin, proxyAdmin);

        // Register the outsider key here, on the single setUp path.
        // halmos adds the "distinct keys give distinct addresses"
        // axioms only on the path that first sees a key (its key cache
        // is shared across forks, halmos 0.3.3). A first sighting
        // inside a forked test path loses the axioms on the sibling
        // paths, and the solver then aliases the outsider with an
        // attestor.
        vm.assume(vm.addr(OUTSIDER_KEY) != address(0));
    }

    /// EIP-1967 admin slot, where the proxy stores its ProxyAdmin address.
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _assumeFreshAddress(address account, address proxyAdmin) internal view {
        vm.assume(account != proxyAdmin);
        vm.assume(account != address(bridge) && account != address(implementation));
        vm.assume(account != RECEIVER);
    }

    /// secp256k1's group order, for the low-s normalization below.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// forge's concrete vm.sign always returns a low-s signature, but
    /// the halmos model leaves s anywhere in the group order, and
    /// OpenZeppelin's ECDSA rejects the upper half as malleable. This
    /// override assumes s into the low half, which matches forge.
    /// It must be vm.assume, not an if-fold: a branch here forks the
    /// path between two vm.sign calls, and halmos then loses the
    /// second signature's recovery axioms on the sibling branch (its
    /// signature cache is shared across forks, halmos 0.3.3).
    function _sign(uint256 pk, bytes32 digest) internal pure override returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.assume(uint256(s) <= SECP256K1_N / 2);
        return abi.encodePacked(r, s, v);
    }

    /// Calls withdraw as an attestor and reports success instead of
    /// reverting, so a check can assert over both outcomes.
    function _tryWithdraw(bytes memory id, address destination, uint256 amount, uint256 deadline, bytes[] memory sigs)
        internal
        returns (bool ok)
    {
        vm.prank(attestors[0]);
        (ok,) = address(bridge).call(abi.encodeCall(bridge.withdraw, (id, destination, amount, deadline, sigs)));
    }

    /// `threshold` valid attestor signatures over the tuple's digest.
    function _signedByThreshold(bytes memory id, address destination, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes[] memory)
    {
        return _attestorSignatures(bridge.withdrawalDigest(id, destination, amount, deadline), THRESHOLD);
    }

    /// Constrains a tuple so it passes every non-signature check of
    /// withdraw. The authorization proofs use this to speak about the
    /// signature check alone, not about an unrelated early revert.
    function _assumeValidRequest(address destination, uint256 amount, uint256 deadline) internal view {
        vm.assume(destination != address(0) && destination != address(bridge));
        vm.assume(amount != 0 && amount <= FUND);
        vm.assume(deadline >= block.timestamp);
    }
}
