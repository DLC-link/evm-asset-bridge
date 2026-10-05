// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {BitSafeHyperEvmAssetBridge} from "../../src/BitSafeHyperEvmAssetBridge.sol";
import {BridgeAdminActionsTest} from "../manage/BridgeAdminActions.t.sol";
import {DecimalsTest} from "../Decimals.t.sol";
import {DefaultAdminActionsTest} from "../manage/DefaultAdminActions.t.sol";
import {DepositTest} from "../Deposit.t.sol";
import {InitializeTest} from "../Initialize.t.sol";
import {RateLimitTest} from "../RateLimit.t.sol";
import {ReentrancyGuardsTest} from "../ReentrancyGuards.t.sol";
import {RolesTest} from "../Roles.t.sol";
import {TotalLockedTest} from "../TotalLocked.t.sol";
import {UpgradeTest} from "../Upgrade.t.sol";
import {VoidWithdrawRequestTest} from "../VoidWithdrawRequest.t.sol";
import {WithdrawTest} from "../Withdraw.t.sol";
import {WithdrawalHorizonTest} from "../WithdrawalHorizon.t.sol";

// Each contract runs every case of one base suite against the HyperEVM
// variant. The variant changes only `withdraw`, so each suite must pass
// unchanged.

contract BridgeAdminActionsHyperTest is BridgeAdminActionsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract DecimalsHyperTest is DecimalsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract DefaultAdminActionsHyperTest is DefaultAdminActionsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract DepositHyperTest is DepositTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract InitializeHyperTest is InitializeTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract RateLimitHyperTest is RateLimitTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract ReentrancyGuardsHyperTest is ReentrancyGuardsTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract RolesHyperTest is RolesTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract TotalLockedHyperTest is TotalLockedTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract UpgradeHyperTest is UpgradeTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract VoidWithdrawRequestHyperTest is VoidWithdrawRequestTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract WithdrawHyperTest is WithdrawTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}

contract WithdrawalHorizonHyperTest is WithdrawalHorizonTest {
    function _newImplementation() internal override returns (BitSafeEvmAssetBridge) {
        return new BitSafeHyperEvmAssetBridge();
    }
}
