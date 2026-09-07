// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {DecimalsERC20} from "./mocks/DecimalsERC20.sol";
import {NoDecimalsToken} from "./mocks/NoDecimalsToken.sol";
import {RevertingDecimalsERC20} from "./mocks/RevertingDecimalsERC20.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ForceSend} from "./mocks/ForceSend.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// Canton expresses 10 decimal places. ETH has 18. A deposit must therefore be
/// a whole multiple of 1e8 wei, or Canton cannot express the minted amount.
contract DecimalsTest is BridgeTestBase {
    uint8 internal constant CANTON_DECIMALS = 10;
    uint256 internal constant ETH_UNIT = 1e8; // 10 ** (18 - 10)

    BitSafeEvmAssetBridge internal ethBridge;

    function setUp() public override {
        super.setUp();
        ethBridge = _deployBridge(address(0), CANTON_DECIMALS);
        vm.deal(user, 1_000 ether);
    }

    // ------------------------------------------------------------------ views

    function test_ethBridge_derivesEighteenAssetDecimals() public view {
        assertEq(ethBridge.assetDecimals(), 18);
        assertEq(ethBridge.targetDecimals(), CANTON_DECIMALS);
        assertEq(ethBridge.depositUnit(), ETH_UNIT);
    }

    function test_erc20Bridge_readsAssetDecimalsFromToken() public {
        DecimalsERC20 token = new DecimalsERC20(6);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        assertEq(b.assetDecimals(), 6);
        assertEq(b.depositUnit(), 1); // target expresses more places than the asset
    }

    /// Both decimals share the `asset` slot: 20 + 1 + 1 bytes. An upgrade author
    /// depends on this layout, so the test pins it.
    function test_storageLayout_packsBothDecimalsIntoTheAssetSlot() public view {
        bytes32 word = vm.load(address(ethBridge), ethBridge.BRIDGE_STORAGE_LOCATION());
        uint256 expected = (uint256(18) << 160) | (uint256(CANTON_DECIMALS) << 168);
        assertEq(uint256(word), expected); // asset is address(0) here
    }

    /// The same claim with a real asset address, so the low 160 bits are not
    /// all zero. A field reorder or an inserted pad byte fails this test.
    function test_storageLayout_packsBothDecimalsBesideANonZeroAsset() public {
        DecimalsERC20 token = new DecimalsERC20(6);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);

        bytes32 word = vm.load(address(b), b.BRIDGE_STORAGE_LOCATION());
        uint256 expected = uint256(uint160(address(token))) | (uint256(6) << 160) | (uint256(CANTON_DECIMALS) << 168);
        assertEq(uint256(word), expected);
    }

    // --------------------------------------------------------------- deposits

    /// An attestor reads this event's `amount` as wei. A bridge that emits
    /// target units instead under-mints by the whole deposit unit.
    function test_depositETH_emitsTheWeiAmount() public {
        vm.expectEmit(true, true, false, true, address(ethBridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 1);
        vm.prank(user);
        ethBridge.depositETH{value: 1 ether}(DEPOSIT_ID);
    }

    function test_depositERC20_emitsTheBaseUnitAmount() public {
        DecimalsERC20 token = new DecimalsERC20(18);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        token.mint(user, 100 ether);

        vm.startPrank(user);
        token.approve(address(b), 100 ether);
        vm.expectEmit(true, true, false, true, address(b));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 1);
        b.depositERC20(1 ether, DEPOSIT_ID);
        vm.stopPrank();
    }

    function test_depositETH_multipleOfUnit_succeeds() public {
        vm.prank(user);
        ethBridge.depositETH{value: ETH_UNIT}(DEPOSIT_ID);
        assertEq(address(ethBridge).balance, ETH_UNIT);

        vm.prank(user);
        ethBridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        assertEq(address(ethBridge).balance, ETH_UNIT + 1 ether);
    }

    function test_depositETH_nonMultiple_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountNotRepresentable.selector, ETH_UNIT + 1, ETH_UNIT)
        );
        vm.prank(user);
        ethBridge.depositETH{value: ETH_UNIT + 1}(DEPOSIT_ID);
    }

    function test_depositETH_belowUnit_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountNotRepresentable.selector, 1, ETH_UNIT));
        vm.prank(user);
        ethBridge.depositETH{value: 1}(DEPOSIT_ID);
    }

    function test_depositERC20_nonMultiple_reverts() public {
        DecimalsERC20 token = new DecimalsERC20(18);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        token.mint(user, 100 ether);

        vm.startPrank(user);
        token.approve(address(b), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountNotRepresentable.selector, 1 ether + 1, ETH_UNIT)
        );
        b.depositERC20(1 ether + 1, DEPOSIT_ID);
        vm.stopPrank();
    }

    function test_depositERC20_multipleOfUnit_succeeds() public {
        DecimalsERC20 token = new DecimalsERC20(18);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        token.mint(user, 100 ether);

        vm.startPrank(user);
        token.approve(address(b), 100 ether);
        b.depositERC20(1 ether, DEPOSIT_ID);
        vm.stopPrank();
        assertEq(token.balanceOf(address(b)), 1 ether);
    }

    function test_targetDecimalsAboveAssetDecimals_acceptsEveryAmount() public {
        DecimalsERC20 token = new DecimalsERC20(6);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        token.mint(user, 1_000);

        vm.startPrank(user);
        token.approve(address(b), 1_000);
        b.depositERC20(1, DEPOSIT_ID); // one base unit, the smallest amount possible
        vm.stopPrank();
        assertEq(token.balanceOf(address(b)), 1);
    }

    /// ETH cannot reach this case now, because the target stops at 10 and ETH
    /// holds 18. A token that reports the target precision still can.
    function test_targetDecimalsEqualAssetDecimals_acceptsEveryAmount() public {
        DecimalsERC20 token = new DecimalsERC20(CANTON_DECIMALS);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        assertEq(b.depositUnit(), 1);
        token.mint(user, 1_000);

        vm.startPrank(user);
        token.approve(address(b), 1_000);
        b.depositERC20(1, DEPOSIT_ID); // one base unit, the smallest amount possible
        vm.stopPrank();
        assertEq(token.balanceOf(address(b)), 1);
    }

    // ----------------------------------------------------------- initializer

    function test_initialize_assetDecimalsAboveMax_reverts() public {
        DecimalsERC20 token = new DecimalsERC20(19);
        vm.expectRevert(BitSafeEvmAssetBridge.DecimalsOutOfRange.selector);
        _deployBridge(address(token), CANTON_DECIMALS);
    }

    /// The bridge targets Canton, so it rejects a precision the CIP-56 token
    /// standard cannot express. A typo such as 100 for 10 fails loudly here.
    function testFuzz_initialize_targetDecimalsAboveMax_reverts(uint8 targetDecimals_) public {
        targetDecimals_ = uint8(bound(targetDecimals_, uint256(ethBridge.MAX_TARGET_DECIMALS()) + 1, type(uint8).max));
        vm.expectRevert(BitSafeEvmAssetBridge.DecimalsOutOfRange.selector);
        _deployBridge(address(0), targetDecimals_);
    }

    function test_initialize_targetDecimalsAtMax_succeeds() public {
        BitSafeEvmAssetBridge b = _deployBridge(address(0), ethBridge.MAX_TARGET_DECIMALS());
        assertEq(b.targetDecimals(), 10);
        assertEq(b.depositUnit(), ETH_UNIT);
    }

    function test_initialize_assetDecimalsAtMax_succeeds() public {
        DecimalsERC20 token = new DecimalsERC20(18);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        assertEq(b.assetDecimals(), 18);
        assertEq(b.depositUnit(), ETH_UNIT);
    }

    function test_initialize_tokenWithoutDecimalsFunction_reverts() public {
        NoDecimalsToken token = new NoDecimalsToken();
        vm.expectRevert(Errors.FailedCall.selector);
        _deployBridge(address(token), CANTON_DECIMALS);
    }

    /// The named error proves `initialize` really calls `decimals()` on the
    /// asset. The generic failure above cannot prove that on its own.
    function test_initialize_tokenWhoseDecimalsReverts_propagatesTheNamedError() public {
        RevertingDecimalsERC20 token = new RevertingDecimalsERC20();
        vm.expectRevert(RevertingDecimalsERC20.DecimalsUnavailable.selector);
        _deployBridge(address(token), CANTON_DECIMALS);
    }

    /// Zero is the only value the target rejects. No chain expresses whole units
    /// only, and the truncating cast in `Deploy.s.sol` produces a zero from a
    /// `TARGET_DECIMALS` of 256.
    function test_initialize_targetDecimalsZero_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.DecimalsOutOfRange.selector);
        _deployBridge(address(0), 0);
    }

    function test_initialize_zeroDecimalToken_reverts() public {
        DecimalsERC20 token = new DecimalsERC20(0);
        vm.expectRevert(BitSafeEvmAssetBridge.DecimalsOutOfRange.selector);
        _deployBridge(address(token), CANTON_DECIMALS);
    }

    function test_initialize_bothDecimalsAtMinimum_succeeds() public {
        DecimalsERC20 token = new DecimalsERC20(1);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), 1);
        assertEq(b.assetDecimals(), 1);
        assertEq(b.targetDecimals(), 1);
        assertEq(b.depositUnit(), 1);
    }

    function test_initialize_depositBandHoldsNoValidAmount_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        _deployBridgeWith(
            address(0),
            CANTON_DECIMALS,
            BitSafeEvmAssetBridge.Limits(1, ETH_UNIT - 1),
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
        );
    }

    // ---------------------------------------------------------------- limits

    function test_setDepositLimits_bandHoldsNoValidAmount_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(1, ETH_UNIT - 1));
    }

    function test_setDepositLimits_bandHoldsOneValidAmount_succeeds() public {
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(1, ETH_UNIT));
        assertEq(ethBridge.depositLimits().maxAmount, ETH_UNIT);

        vm.prank(user);
        ethBridge.depositETH{value: ETH_UNIT}(DEPOSIT_ID);
        assertEq(address(ethBridge).balance, ETH_UNIT);
    }

    /// A zero minimum reaches only the first clause of the band guard, because
    /// `0 < 0` is false. Without that clause the bridge accepts this band.
    function test_setDepositLimits_zeroMinimumAndNoValidAmount_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(0, ETH_UNIT - 1));
    }

    /// A band that sits between two multiples reaches only the second clause.
    function test_setDepositLimits_bandBetweenTwoMultiples_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.InvalidLimits.selector);
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(15e7, 19e7));
    }

    /// A band holding exactly one valid amount must pass. This pins the
    /// comparison operator, which `<=` would break.
    function test_setDepositLimits_singleValueBand_succeeds() public {
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(ETH_UNIT, ETH_UNIT));

        vm.prank(user);
        ethBridge.depositETH{value: ETH_UNIT}(DEPOSIT_ID);
        assertEq(address(ethBridge).balance, ETH_UNIT);
    }

    function test_setWithdrawLimits_ignoresDepositUnit() public {
        vm.prank(bridgeAdmin);
        ethBridge.setWithdrawLimits(BitSafeEvmAssetBridge.Limits(1, ETH_UNIT - 1));
        assertEq(ethBridge.withdrawLimits().maxAmount, ETH_UNIT - 1);
    }

    function test_depositETH_limitsCheckRunsBeforeGranularityCheck() public {
        vm.prank(bridgeAdmin);
        ethBridge.setDepositLimits(BitSafeEvmAssetBridge.Limits(1 ether, 10 ether));

        // 11 ether + 1 wei breaks both rules. The limits error must win.
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountOutsideLimits.selector, 11 ether + 1, 1 ether, 10 ether)
        );
        vm.prank(user);
        ethBridge.depositETH{value: 11 ether + 1}(DEPOSIT_ID);
    }

    // ------------------------------------------------------------ withdrawals

    /// The withdraw path stays free of the granularity check by design.
    function test_withdraw_nonMultipleAmount_succeeds() public {
        vm.prank(user);
        ethBridge.depositETH{value: 100 ether}(DEPOSIT_ID);

        address destination = makeAddr("destination");
        uint256 amount = 1 ether + 1; // not a multiple of ETH_UNIT
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = ethBridge.withdrawalDigest(REQUEST_ID, destination, amount, deadline);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        ethBridge.withdraw(REQUEST_ID, destination, amount, deadline, sigs);
        assertEq(destination.balance, amount);
        assertTrue(ethBridge.isWithdrawRequestUsed(REQUEST_ID));
    }

    // --------------------------------------------- the shipped configuration

    // These two paths meet the granularity check but must not obey it. The pause
    // rejects a valid multiple, and the rescue moves a non-multiple balance.

    function test_depositETH_whenPaused_revertsBeforeTheGranularityCheck() public {
        vm.prank(bridgeAdmin);
        ethBridge.pause();

        // The amount is a valid multiple, so only the pause can reject it.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        ethBridge.depositETH{value: ETH_UNIT}(DEPOSIT_ID);
    }

    /// The rescue path must stay free of the granularity rule. Forced ETH does
    /// not respect the deposit unit, and the admin must still recover it.
    function test_rescueETH_movesANonMultipleBalance() public {
        DecimalsERC20 token = new DecimalsERC20(18);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        uint256 dust = ETH_UNIT + 1; // not a multiple of the deposit unit

        ForceSend forcer = new ForceSend{value: dust}();
        forcer.boom(payable(address(b)));
        assertEq(address(b).balance, dust);

        address recipient = makeAddr("rescueRecipient");
        vm.prank(bridgeAdmin);
        b.rescueETH(recipient, dust);
        assertEq(recipient.balance, dust);
        assertEq(address(b).balance, 0);
    }

    // ------------------------------------------------------------------ fuzz

    /// Fuzz the multiplier, not the wei amount. A raw wei draw is a multiple of
    /// 1e8 about once in 1e8 tries, so it never really tests the accept path.
    function testFuzz_depositETH_multiplesSucceed(uint256 raw) public {
        uint256 amount = bound(raw, 1, 100 ether / ETH_UNIT) * ETH_UNIT;
        vm.prank(user);
        ethBridge.depositETH{value: amount}(DEPOSIT_ID);
        assertEq(address(ethBridge).balance, amount);
    }

    function testFuzz_depositETH_nonMultiplesRevert(uint256 raw, uint256 offset) public {
        uint256 amount = bound(raw, 0, 100 ether / ETH_UNIT - 1) * ETH_UNIT + bound(offset, 1, ETH_UNIT - 1);
        vm.expectRevert(abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountNotRepresentable.selector, amount, ETH_UNIT));
        vm.prank(user);
        ethBridge.depositETH{value: amount}(DEPOSIT_ID);
    }
}
