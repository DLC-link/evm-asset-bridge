// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
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
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 0);
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
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 5 ether, 0);
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

    // ---------------------------------------------------------- deposit links

    /// The README publishes this value for event consumers.
    function test_depositEvent_topic0() public pure {
        assertEq(
            BitSafeEvmAssetBridge.Deposit.selector, 0xf3ca88974ec5963addc617fe6c0c359d7196759e318be6ab0cade940986e30e2
        );
    }

    function test_depositETH_firstDeposit_linksToZero() public {
        vm.roll(100);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 0);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);
    }

    function test_depositERC20_firstDeposit_linksToZero() public {
        vm.roll(100);
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 1 ether);
        vm.expectEmit(true, true, false, true, address(erc20Bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 0);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);
        vm.stopPrank();
        assertEq(erc20Bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);
    }

    function test_depositETH_laterBlock_linksToPreviousDeposit() public {
        vm.roll(100);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        vm.roll(105);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 2 ether, 100);
        vm.prank(user);
        bridge.depositETH{value: 2 ether}(DEPOSIT_ID);
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 105);
    }

    function test_depositERC20_laterBlock_linksToPreviousDeposit() public {
        vm.prank(user);
        token.approve(address(erc20Bridge), 3 ether);

        vm.roll(100);
        vm.prank(user);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);

        vm.roll(105);
        vm.expectEmit(true, true, false, true, address(erc20Bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 2 ether, 100);
        vm.prank(user);
        erc20Bridge.depositERC20(2 ether, DEPOSIT_ID);
        assertEq(erc20Bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 105);
    }

    /// A reader that sees `prevDepositBlock == block.number` reads the same
    /// block again, so it must follow the lowest link below that block.
    function test_deposit_sameBlock_linksToTheSameBlock() public {
        vm.roll(100);
        vm.startPrank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 2 ether, 100);
        bridge.depositETH{value: 2 ether}(DEPOSIT_ID);
        vm.stopPrank();
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);
    }

    function test_deposit_twoAccounts_keepSeparateLinks() public {
        bytes memory otherId = hex"00ffeedd";
        vm.startPrank(user);
        vm.roll(100);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        vm.roll(101);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(otherId), otherId, user, 1 ether, 0);
        bridge.depositETH{value: 1 ether}(otherId);

        vm.roll(102);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 100);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        vm.stopPrank();

        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 102);
        assertEq(bridge.lastDepositBlock(keccak256(otherId)), 101);
    }

    function test_deposit_revert_keepsTheLink() public {
        vm.roll(100);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        vm.roll(105);
        uint256 badAmount = 1 ether + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BitSafeEvmAssetBridge.AmountNotRepresentable.selector, badAmount, DEFAULT_DEPOSIT_UNIT
            )
        );
        vm.prank(user);
        bridge.depositETH{value: badAmount}(DEPOSIT_ID);
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);
    }

    function test_deposit_revertOnFirstDeposit_leavesNoLink() public {
        vm.roll(100);
        uint256 badAmount = 1 ether + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BitSafeEvmAssetBridge.AmountNotRepresentable.selector, badAmount, DEFAULT_DEPOSIT_UNIT
            )
        );
        vm.prank(user);
        bridge.depositETH{value: badAmount}(DEPOSIT_ID);
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 0);
    }

    /// The token transfer runs before the link. A deposit that fails there
    /// leaves no gap in the chain: the next deposit links past it.
    function test_depositERC20_revert_nextDepositLinksPastIt() public {
        vm.prank(user);
        token.approve(address(erc20Bridge), 1 ether);
        vm.roll(100);
        vm.prank(user);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);

        vm.roll(105);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(erc20Bridge), 0, 1 ether)
        );
        vm.prank(user);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);
        assertEq(erc20Bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);

        vm.roll(110);
        vm.startPrank(user);
        token.approve(address(erc20Bridge), 1 ether);
        vm.expectEmit(true, true, false, true, address(erc20Bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 1 ether, 100);
        erc20Bridge.depositERC20(1 ether, DEPOSIT_ID);
        vm.stopPrank();
    }

    function test_deposit_whenPaused_keepsTheLink() public {
        vm.roll(100);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);

        vm.roll(105);
        vm.prank(bridgeAdmin);
        bridge.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user);
        bridge.depositETH{value: 1 ether}(DEPOSIT_ID);
        assertEq(bridge.lastDepositBlock(keccak256(DEPOSIT_ID)), 100);

        vm.roll(110);
        vm.prank(bridgeAdmin);
        bridge.unpause();
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BitSafeEvmAssetBridge.Deposit(keccak256(DEPOSIT_ID), DEPOSIT_ID, user, 2 ether, 100);
        vm.prank(user);
        bridge.depositETH{value: 2 ether}(DEPOSIT_ID);
    }

    /// Walks the links the way the README tells a reader to, over random
    /// blocks and accounts, and finds every deposit after the start block.
    function testFuzz_depositLinks_walkFindsEveryDepositAfterStart(
        uint8[16] memory gaps,
        uint8[16] memory accounts,
        uint8 rawCount,
        uint256 rawStart
    ) public {
        bytes[3] memory ids = [bytes(hex"0a01"), bytes(hex"0a02"), bytes(hex"0a03")];
        uint256 count = bound(rawCount, 1, 16);
        uint256[] memory depositBlock = new uint256[](count);
        uint256[] memory depositAccount = new uint256[](count);
        Vm.Log[] memory logs = new Vm.Log[](count);

        vm.roll(1000);
        vm.startPrank(user);
        for (uint256 i; i < count; ++i) {
            // A gap of 0 puts the deposit in the same block as the one before.
            vm.roll(block.number + gaps[i] % 4);
            depositBlock[i] = block.number;
            depositAccount[i] = accounts[i] % 3;
            vm.recordLogs();
            bridge.depositETH{value: (i + 1) * 1 ether}(ids[depositAccount[i]]);
            logs[i] = vm.getRecordedLogs()[0];
        }
        vm.stopPrank();
        uint256 start = bound(rawStart, 999, block.number);

        for (uint256 a; a < 3; ++a) {
            bytes32 idHash = keccak256(ids[a]);
            uint256 found;
            uint256 foundAmount;
            uint256 link = bridge.lastDepositBlock(idHash);
            while (link > start) {
                uint256 next = type(uint256).max;
                // The `Deposit` logs of the account at block `link`.
                for (uint256 i; i < count; ++i) {
                    if (depositBlock[i] != link || logs[i].emitter != address(bridge)) continue;
                    if (logs[i].topics[0] != BitSafeEvmAssetBridge.Deposit.selector) continue;
                    if (logs[i].topics[1] != idHash) continue;
                    (, uint256 amount, uint256 prev) = abi.decode(logs[i].data, (bytes, uint256, uint256));
                    ++found;
                    foundAmount += amount;
                    if (prev < next) next = prev;
                }
                assertLt(next, link);
                link = next;
            }

            uint256 expected;
            uint256 expectedAmount;
            for (uint256 i; i < count; ++i) {
                if (depositAccount[i] == a && depositBlock[i] > start) {
                    ++expected;
                    expectedAmount += (i + 1) * 1 ether;
                }
            }
            assertEq(found, expected);
            assertEq(foundAmount, expectedAmount);
        }
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
