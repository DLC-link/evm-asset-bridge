// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Pause} from "../../script/manage/BitSafeEvmAssetBridge/Pause.s.sol";
import {Unpause} from "../../script/manage/BitSafeEvmAssetBridge/Unpause.s.sol";
import {SetThreshold} from "../../script/manage/BitSafeEvmAssetBridge/SetThreshold.s.sol";
import {SetDepositLimits} from "../../script/manage/BitSafeEvmAssetBridge/SetDepositLimits.s.sol";
import {SetWithdrawLimits} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawLimits.s.sol";
import {SetWithdrawRateLimit} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawRateLimit.s.sol";
import {SetWithdrawalHorizon} from "../../script/manage/BitSafeEvmAssetBridge/SetWithdrawalHorizon.s.sol";
import {RescueERC20} from "../../script/manage/BitSafeEvmAssetBridge/RescueERC20.s.sol";
import {RescueETH} from "../../script/manage/BitSafeEvmAssetBridge/RescueETH.s.sol";
import {RescueSurplus} from "../../script/manage/BitSafeEvmAssetBridge/RescueSurplus.s.sol";
import {VoidWithdrawRequest} from "../../script/manage/BitSafeEvmAssetBridge/VoidWithdrawRequest.s.sol";

contract BridgeAdminActionsTest is BridgeTestBase {
    /// Sends one script's calldata from the bridge admin and requires success.
    function _run(bytes memory data) internal {
        vm.prank(bridgeAdmin);
        (bool ok, bytes memory ret) = address(bridge).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function test_pause() public {
        _run(new Pause().encode());
        assertTrue(bridge.paused());
    }

    function test_unpause() public {
        _run(new Pause().encode());
        _run(new Unpause().encode());
        assertFalse(bridge.paused());
    }

    function test_setThreshold() public {
        _run(new SetThreshold().encode(3));
        assertEq(bridge.threshold(), 3);
    }

    function test_setDepositLimits() public {
        _run(new SetDepositLimits().encode(2e8, 9e8));
        assertEq(bridge.depositLimits().minAmount, 2e8);
        assertEq(bridge.depositLimits().maxAmount, 9e8);
    }

    function test_setWithdrawLimits() public {
        _run(new SetWithdrawLimits().encode(1, 7e8));
        assertEq(bridge.withdrawLimits().minAmount, 1);
        assertEq(bridge.withdrawLimits().maxAmount, 7e8);
    }

    function test_setWithdrawRateLimit() public {
        _run(new SetWithdrawRateLimit().encode(5 ether, 1 days));
        (uint208 capacity, uint48 window,) = bridge.withdrawRateLimit();
        assertEq(capacity, 5 ether);
        assertEq(window, 1 days);
    }

    function test_setWithdrawRateLimit_rejectsAnOutOfRangeCapacity() public {
        SetWithdrawRateLimit script = new SetWithdrawRateLimit();
        vm.expectRevert(bytes("capacity exceeds uint208"));
        script.encode(uint256(type(uint208).max) + 1, 1 days);
    }

    function test_setWithdrawRateLimit_rejectsAnOutOfRangeWindow() public {
        SetWithdrawRateLimit script = new SetWithdrawRateLimit();
        vm.expectRevert(bytes("window exceeds uint48"));
        script.encode(5 ether, uint256(type(uint48).max) + 1);
    }

    function test_setWithdrawalHorizon() public {
        _run(new SetWithdrawalHorizon().encode(48 hours));
        assertEq(bridge.withdrawalHorizon(), 48 hours);
    }

    function test_rescueERC20() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(bridge), 100);
        _run(new RescueERC20().encode(address(stray), user, 100));
        assertEq(stray.balanceOf(user), 100);
    }

    function test_rescueETH() public {
        // rescueETH works on an ERC20 instance only, so this fixture uses one.
        MockERC20 asset = new MockERC20();
        bridge = _deployBridge(address(asset));
        vm.deal(address(bridge), 1 ether);
        _run(new RescueETH().encode(user, 1 ether));
        assertEq(user.balance, 1 ether);
    }

    function test_rescueSurplus() public {
        vm.deal(address(bridge), 3 ether);
        _run(new RescueSurplus().encode(user, 3 ether));
        assertEq(user.balance, 3 ether);
    }

    function test_voidWithdrawRequest() public {
        _run(new VoidWithdrawRequest().encode(REQUEST_ID));
        assertTrue(bridge.isWithdrawRequestUsed(REQUEST_ID));
    }
}
