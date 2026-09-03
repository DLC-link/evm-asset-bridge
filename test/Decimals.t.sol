// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {DecimalsERC20} from "./mocks/DecimalsERC20.sol";
import {NoDecimalsToken} from "./mocks/NoDecimalsToken.sol";

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

    // --------------------------------------------------------------- deposits

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

    function test_targetDecimalsEqualAssetDecimals_acceptsEveryAmount() public {
        BitSafeEvmAssetBridge b = _deployBridge(address(0), 18);
        assertEq(b.depositUnit(), 1);
        vm.prank(user);
        b.depositETH{value: 1}(DEPOSIT_ID);
        assertEq(address(b).balance, 1);
    }

    // ----------------------------------------------------------- initializer

    function test_initialize_assetDecimalsAboveMax_reverts() public {
        DecimalsERC20 token = new DecimalsERC20(78);
        vm.expectRevert(BitSafeEvmAssetBridge.DecimalsOutOfRange.selector);
        _deployBridge(address(token), CANTON_DECIMALS);
    }

    function test_initialize_assetDecimalsAtMax_succeeds() public {
        DecimalsERC20 token = new DecimalsERC20(77);
        BitSafeEvmAssetBridge b = _deployBridge(address(token), CANTON_DECIMALS);
        assertEq(b.depositUnit(), 10 ** 67);
    }

    function test_initialize_tokenWithoutDecimalsFunction_reverts() public {
        NoDecimalsToken token = new NoDecimalsToken();
        vm.expectRevert();
        _deployBridge(address(token), CANTON_DECIMALS);
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
        bytes32 digest = ethBridge.withdrawalDigest(REQUEST_ID, destination, amount);
        bytes[] memory sigs = _attestorSignatures(digest, 2);
        vm.prank(attestors[0]);
        ethBridge.withdraw(REQUEST_ID, destination, amount, sigs);
        assertEq(destination.balance, amount);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_depositETH_onlyMultiplesSucceed(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        if (amount % ETH_UNIT == 0) {
            vm.prank(user);
            ethBridge.depositETH{value: amount}(DEPOSIT_ID);
            assertEq(address(ethBridge).balance, amount);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountNotRepresentable.selector, amount, ETH_UNIT)
            );
            vm.prank(user);
            ethBridge.depositETH{value: amount}(DEPOSIT_ID);
        }
    }
}
