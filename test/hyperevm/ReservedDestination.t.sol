// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// Each case calls `withdraw` with a valid threshold of signatures, so the
/// destination is the only input that can fail.
contract ReservedDestinationHyperTest is BridgeTestBase {
    address internal constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    address internal constant TOKEN_BOTTOM = 0x2000000000000000000000000000000000000000;
    address internal constant TOKEN_ONE = 0x2000000000000000000000000000000000000001;
    address internal constant TOKEN_HYPE = 0x2000000000000000000000000000000000000096;
    address internal constant TOKEN_TOP = 0x20000000000000000000000000000000FffFFFfF;
    address internal constant TOKEN_ABOVE_TOP = 0x2000000000000000000000000000000100000000;
    address internal constant TOKEN_BELOW_BOTTOM = 0x1fFfFffffFfffFFfFffffFFFfffFFfffFfffFFFF;
    address internal constant FIRST_BYTE_0X21 = 0x2100000000000000000000000000000000000000;
    address internal constant MIDDLE_BYTE_SET = 0x2000000100000000000000000000000000000000;

    uint256 internal constant AMOUNT = 1 ether;
    uint208 internal constant RATE_CAPACITY = 5 ether;
    uint48 internal constant RATE_WINDOW = 1 days;
    uint256 internal deadline;

    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 1 hours;
        vm.deal(user, 100 ether);
        vm.prank(user);
        bridge.depositETH{value: 10 ether}(DEPOSIT_ID);
        // A live rate limit makes the "budget unchanged" check meaningful.
        vm.prank(bridgeAdmin);
        bridge.setWithdrawRateLimit(RATE_CAPACITY, RATE_WINDOW);
    }

    function _signatures(BitSafeEvmAssetBridge b, bytes memory id, address dest)
        internal
        view
        returns (bytes[] memory)
    {
        return _attestorSignatures(b.withdrawalDigest(id, dest, AMOUNT, deadline), THRESHOLD);
    }

    function _pay(bytes memory id, address dest) internal {
        bytes[] memory sigs = _signatures(bridge, id, dest);
        vm.prank(attestors[0]);
        bridge.withdraw(id, dest, AMOUNT, deadline, sigs);
    }

    function _expectPays(address dest) internal {
        uint256 before = dest.balance;
        _pay(REQUEST_ID, dest);
        assertEq(dest.balance - before, AMOUNT);
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    function _expectRefused(address dest, bytes memory err) internal {
        uint256 lockedBefore = bridge.totalLocked();
        uint256 balanceBefore = address(bridge).balance;
        (,, uint256 budgetBefore) = bridge.withdrawRateLimit();
        bytes[] memory sigs = _signatures(bridge, REQUEST_ID, dest);

        vm.recordLogs();
        vm.prank(attestors[0]);
        vm.expectRevert(err);
        bridge.withdraw(REQUEST_ID, dest, AMOUNT, deadline, sigs);

        // The revert leaves no trace: no event, no used id, no moved funds.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertFalse(bridge.isWithdrawRequestUsed(REQUEST_ID));
        assertEq(bridge.totalLocked(), lockedBefore);
        assertEq(address(bridge).balance, balanceBefore);
        (,, uint256 budgetAfter) = bridge.withdrawRateLimit();
        assertEq(budgetAfter, budgetBefore);

        // The same id then pays a valid destination.
        address retry = makeAddr("retry");
        _pay(REQUEST_ID, retry);
        assertEq(retry.balance, AMOUNT);
    }

    function _reserved(address dest) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BitSafeHyperEvmAssetBridge.ReservedDestination.selector, dest);
    }

    function _invalid() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BitSafeEvmAssetBridge.InvalidDestination.selector);
    }

    function test_hypeSystemAddress_isRefused() public {
        _expectRefused(HYPE_SYSTEM, _reserved(HYPE_SYSTEM));
    }

    function test_tokenRangeBottom_isRefused() public {
        _expectRefused(TOKEN_BOTTOM, _reserved(TOKEN_BOTTOM));
    }

    function test_tokenIndexOne_isRefused() public {
        _expectRefused(TOKEN_ONE, _reserved(TOKEN_ONE));
    }

    function test_tokenIndexOfHype_isRefused() public {
        _expectRefused(TOKEN_HYPE, _reserved(TOKEN_HYPE));
    }

    function test_tokenRangeTop_isRefused() public {
        _expectRefused(TOKEN_TOP, _reserved(TOKEN_TOP));
    }

    function test_oneAboveTokenRangeTop_pays() public {
        _expectPays(TOKEN_ABOVE_TOP);
    }

    function test_oneBelowTokenRangeBottom_pays() public {
        _expectPays(TOKEN_BELOW_BOTTOM);
    }

    function test_firstByte0x21_pays() public {
        _expectPays(FIRST_BYTE_0X21);
    }

    function test_nonZeroMiddleByte_pays() public {
        _expectPays(MIDDLE_BYTE_SET);
    }

    function test_ordinaryEoa_pays() public {
        _expectPays(makeAddr("ordinary"));
    }

    /// The variant keeps the base refusals, so its override calls super.
    function test_zeroAddress_revertsInvalidDestination() public {
        _expectRefused(address(0), _invalid());
    }

    function test_bridgeItself_revertsInvalidDestination() public {
        _expectRefused(address(bridge), _invalid());
    }

    function testFuzz_everyTokenIndexIsRefused(uint32 index) public {
        address dest = address(uint160(TOKEN_BOTTOM) + index);
        _expectRefused(dest, _reserved(dest));
    }

    /// Any address outside the HYPE system address and the token range pays. The test leaves out the two
    /// base refusals, and the addresses that cannot take a plain value
    /// transfer: precompiles, forge's own addresses, and accounts with code.
    /// Those fail for reasons that have nothing to do with this list.
    function testFuzz_noOtherAddressIsReserved(address dest) public {
        vm.assume(dest != address(0) && dest != address(bridge));
        vm.assume(dest != HYPE_SYSTEM);
        vm.assume(uint160(dest) >> 32 != uint160(TOKEN_BOTTOM) >> 32);
        vm.assume(dest.code.length == 0);
        assumeNotPrecompile(dest);
        assumeNotForgeAddress(dest);
        _expectPays(dest);
    }

    /// The attestor builds every digest with the base domain name.
    function test_eip712Domain_keepsTheBaseName() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            bridge.eip712Domain();
        assertEq(name, "BitSafeEvmAssetBridge");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(bridge));
    }

    /// A token sent to its system address also moves to HyperCore, so an
    /// ERC20 bridge refuses the same list.
    function test_erc20Bridge_refusesReservedDestinations() public {
        MockERC20 token = new MockERC20();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        token.mint(user, 10 ether);
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 10 ether);
        erc20Bridge.depositERC20(10 ether, DEPOSIT_ID);
        vm.stopPrank();

        address[2] memory reserved = [HYPE_SYSTEM, TOKEN_HYPE];
        for (uint256 i; i < reserved.length; ++i) {
            bytes[] memory sigs = _signatures(erc20Bridge, REQUEST_ID, reserved[i]);
            vm.prank(attestors[0]);
            vm.expectRevert(_reserved(reserved[i]));
            erc20Bridge.withdraw(REQUEST_ID, reserved[i], AMOUNT, deadline, sigs);
        }
        assertEq(token.balanceOf(address(erc20Bridge)), 10 ether);
    }
}

/// The EIP-712 domain includes the proxy address. One proxy that changes
/// its implementation therefore shows that both contracts build the same
/// digest. The fixture here deploys the base contract.
contract CrossContractDigestTest is BridgeTestBase {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function test_baseSignaturesPayAfterAnUpgradeToTheVariant() public {
        address destination = makeAddr("destination");
        uint256 deadline = block.timestamp + 1 hours;
        vm.deal(user, 10 ether);
        vm.prank(user);
        bridge.depositETH{value: 10 ether}(DEPOSIT_ID);

        bytes32 baseDigest = bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline);
        bytes[] memory sigs = _attestorSignatures(baseDigest, THRESHOLD);

        address proxyAdmin = address(uint160(uint256(vm.load(address(bridge), ADMIN_SLOT))));
        address variant = address(new BitSafeHyperEvmAssetBridge());
        vm.prank(proxyOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(address(bridge))), variant, "");

        assertEq(bridge.withdrawalDigest(REQUEST_ID, destination, 1 ether, deadline), baseDigest);
        vm.prank(attestors[0]);
        bridge.withdraw(REQUEST_ID, destination, 1 ether, deadline, sigs);
        assertEq(destination.balance, 1 ether);
    }
}
