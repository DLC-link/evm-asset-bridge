// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "./BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../src/BitSafeEvmAssetBridge.sol";
import {HookToken} from "./mocks/HookToken.sol";
import {ReentrantCaller} from "./mocks/ReentrantCaller.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// Proves the reentrancy guard on the four value-moving functions that make
/// an external call outside `withdraw`: depositERC20, rescueERC20, rescueETH,
/// and rescueSurplus. Each test hands the external call to a hook (an
/// ERC777-style token or an ETH receiver) that reenters the same function and
/// records the inner revert. Withdraw.t.sol covers `withdraw` itself.
contract ReentrancyGuardsTest is BridgeTestBase {
    bytes internal GUARD_REVERT =
        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    function test_depositERC20_reentrancy_blocked() public {
        HookToken hook = new HookToken();
        BitSafeEvmAssetBridge hookBridge = _deployBridge(address(hook));
        hook.mint(user, 100 ether);
        vm.prank(user);
        hook.approve(address(hookBridge), type(uint256).max);

        // The inner call runs with the token as msg.sender; depositERC20 has
        // no role gate, so the guard is the first thing that can stop it.
        hook.arm(address(hookBridge), abi.encodeCall(BitSafeEvmAssetBridge.depositERC20, (1 ether, DEPOSIT_ID)));

        vm.prank(user);
        hookBridge.depositERC20(2 ether, DEPOSIT_ID);

        assertTrue(hook.callbackRan());
        assertFalse(hook.callbackSucceeded());
        assertEq(hook.callbackRevertData(), GUARD_REVERT);
        // Exactly the outer deposit locked; the reentered one left no trace.
        assertEq(hookBridge.totalLocked(), 2 ether);
        assertEq(hook.balanceOf(address(hookBridge)), 2 ether);
    }

    function test_rescueERC20_reentrancy_blocked() public {
        // ETH instance: any ERC20 is foreign, so the hook token is rescuable.
        HookToken stray = new HookToken();
        stray.mint(address(bridge), 5 ether);
        // The inner call runs with the token as msg.sender, so the token
        // needs the admin role to get past onlyRole and reach the guard.
        bytes32 adminRole = bridge.BRIDGE_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(adminRole, address(stray));

        stray.arm(address(bridge), abi.encodeCall(BitSafeEvmAssetBridge.rescueERC20, (address(stray), user, 2 ether)));

        vm.prank(bridgeAdmin);
        bridge.rescueERC20(address(stray), user, 2 ether);

        assertTrue(stray.callbackRan());
        assertFalse(stray.callbackSucceeded());
        assertEq(stray.callbackRevertData(), GUARD_REVERT);
        assertEq(stray.balanceOf(user), 2 ether); // paid exactly once
    }

    function test_rescueETH_reentrancy_blocked() public {
        // ERC20 instance: ETH is foreign, so rescueETH is live.
        HookToken token = new HookToken();
        BitSafeEvmAssetBridge erc20Bridge = _deployBridge(address(token));
        vm.deal(address(erc20Bridge), 5 ether); // stray ETH to rescue

        ReentrantCaller caller = new ReentrantCaller();
        // The inner call runs with the receiver as msg.sender, so the
        // receiver needs the admin role to get past onlyRole and reach the guard.
        bytes32 adminRole = erc20Bridge.BRIDGE_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        erc20Bridge.grantRole(adminRole, address(caller));

        caller.arm(address(erc20Bridge), abi.encodeCall(BitSafeEvmAssetBridge.rescueETH, (address(caller), 2 ether)));

        vm.prank(bridgeAdmin);
        erc20Bridge.rescueETH(address(caller), 2 ether);

        assertTrue(caller.reentered());
        assertFalse(caller.callbackSucceeded());
        assertEq(caller.callbackRevertData(), GUARD_REVERT);
        assertEq(address(caller).balance, 2 ether); // paid exactly once
    }

    function test_rescueSurplus_erc20_reentrancy_blocked() public {
        HookToken hook = new HookToken();
        BitSafeEvmAssetBridge hookBridge = _deployBridge(address(hook));
        // A direct mint to the bridge is unaccounted balance: pure surplus.
        hook.mint(address(hookBridge), 3 ether);
        assertEq(hookBridge.surplus(), 3 ether);
        bytes32 adminRole = hookBridge.BRIDGE_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        hookBridge.grantRole(adminRole, address(hook));

        hook.arm(address(hookBridge), abi.encodeCall(BitSafeEvmAssetBridge.rescueSurplus, (user, 1 ether)));

        vm.prank(bridgeAdmin);
        hookBridge.rescueSurplus(user, 1 ether);

        assertTrue(hook.callbackRan());
        assertFalse(hook.callbackSucceeded());
        assertEq(hook.callbackRevertData(), GUARD_REVERT);
        assertEq(hook.balanceOf(user), 1 ether); // paid exactly once
        assertEq(hookBridge.surplus(), 2 ether);
    }

    function test_rescueSurplus_eth_reentrancy_blocked() public {
        // ETH arm: the surplus payout is a raw call, the classic reentry point.
        vm.deal(address(bridge), 3 ether); // unaccounted ETH: pure surplus
        assertEq(bridge.surplus(), 3 ether);

        ReentrantCaller caller = new ReentrantCaller();
        bytes32 adminRole = bridge.BRIDGE_ADMIN_ROLE();
        vm.prank(defaultAdmin);
        bridge.grantRole(adminRole, address(caller));

        caller.arm(address(bridge), abi.encodeCall(BitSafeEvmAssetBridge.rescueSurplus, (address(caller), 1 ether)));

        vm.prank(bridgeAdmin);
        bridge.rescueSurplus(address(caller), 1 ether);

        assertTrue(caller.reentered());
        assertFalse(caller.callbackSucceeded());
        assertEq(caller.callbackRevertData(), GUARD_REVERT);
        assertEq(address(caller).balance, 1 ether); // paid exactly once
        assertEq(bridge.surplus(), 2 ether);
    }
}
