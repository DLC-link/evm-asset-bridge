// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract DepositTest is BridgeTestBase {
    MockERC20 internal token;
    BitSafeEvmAssetBridge internal erc20Bridge;

    function setUp() public override {
        super.setUp();
        token = new MockERC20();
        erc20Bridge = _deployBridge(address(token));
        token.mint(user, 1_000 ether);
        vm.deal(user, 1_000 ether);
    }

    function test_depositETH_locksAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        assertEq(address(bridge).balance, 1 ether);
    }

    function test_depositETH_onErc20Instance_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.AssetIsNotEther.selector);
        vm.prank(user);
        erc20Bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
    }

    function test_depositETH_emptyId_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.EmptyId.selector);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}("");
    }

    function test_depositETH_zeroAmount_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.ZeroAmount.selector);
        vm.prank(user);
        bridge.depositETH{value: 0}(DEPOSIT_ID);
    }

    function test_depositERC20_locksAndEmits() public {
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 5 ether);
        vm.expectEmit(true, true, false, true);
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 5 ether);
        erc20Bridge.depositERC20(5 ether, DEPOSIT_ID);
        vm.stopPrank();
        assertEq(token.balanceOf(address(erc20Bridge)), 5 ether);
    }

    function test_depositERC20_onEthInstance_reverts() public {
        vm.expectRevert(BitSafeEvmAssetBridge.AssetIsNotERC20.selector);
        vm.prank(user);
        bridge.depositERC20(1 ether, DEPOSIT_ID);
    }

    function test_depositERC20_feeOnTransfer_reverts() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        BitSafeEvmAssetBridge feeBridge = _deployBridge(address(feeToken));
        feeToken.mint(user, 100 ether);
        vm.startPrank(user);
        feeToken.approve(address(feeBridge), 100 ether);
        vm.expectRevert(BitSafeEvmAssetBridge.UnexpectedBalanceChange.selector);
        feeBridge.depositERC20(100 ether, DEPOSIT_ID);
        vm.stopPrank();
    }

    function test_depositLimits_inclusiveBounds() public {
        BitSafeEvmAssetBridge bounded = _deployBridgeWithDepositLimits(1 ether, 10 ether);
        vm.startPrank(user);
        bounded.depositETH{value: 1 ether}(DEPOSIT_ID); // at min: passes
        bounded.depositETH{value: 10 ether}(DEPOSIT_ID); // at max: passes
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountOutsideLimits.selector, 0.5 ether, 1 ether, 10 ether)
        );
        bounded.depositETH{value: 0.5 ether}(DEPOSIT_ID);
        vm.expectRevert(
            abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountOutsideLimits.selector, 11 ether, 1 ether, 10 ether)
        );
        bounded.depositETH{value: 11 ether}(DEPOSIT_ID);
        vm.stopPrank();
    }

    /// Every drawn amount is a whole multiple of the deposit unit, so the limits
    /// band is the only rule under test. Decimals.t.sol fuzzes the granularity
    /// rule on its own.
    function testFuzz_depositETH_respectsLimits(uint96 raw) public {
        BitSafeEvmAssetBridge bounded = _deployBridgeWithDepositLimits(1 ether, 10 ether);
        uint256 amount = bound(uint256(raw), 1, 20 ether / DEFAULT_DEPOSIT_UNIT) * DEFAULT_DEPOSIT_UNIT;
        vm.deal(user, type(uint96).max);
        vm.prank(user);
        if (amount >= 1 ether && amount <= 10 ether) {
            bounded.depositETH{value: amount}(DEPOSIT_ID);
            assertEq(address(bounded).balance, amount);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(BitSafeEvmAssetBridge.AmountOutsideLimits.selector, amount, 1 ether, 10 ether)
            );
            bounded.depositETH{value: amount}(DEPOSIT_ID);
        }
    }

    function test_directEthTransfer_reverts() public {
        vm.prank(user);
        (bool ok,) = address(bridge).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(user);
        (ok,) = address(bridge).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
    }

    function test_depositETH_whenPaused_reverts() public {
        vm.prank(bridgeAdmin);
        bridge.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
    }

    function test_depositERC20_whenPaused_reverts() public {
        vm.prank(bridgeAdmin);
        erc20Bridge.pause();
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 1 ether);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);
        vm.stopPrank();
    }

    function _deployBridgeWithDepositLimits(uint256 minAmount, uint256 maxAmount)
        internal
        returns (BitSafeEvmAssetBridge)
    {
        return _deployBridgeWith(
            address(0),
            DEFAULT_TARGET_DECIMALS,
            BitSafeEvmAssetBridge.Limits(minAmount, maxAmount),
            BitSafeEvmAssetBridge.Limits(0, type(uint256).max)
        );
    }
}
