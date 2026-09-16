// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BridgeTestBase} from "../BridgeTestBase.t.sol";
import {BitSafeEvmAssetBridge} from "../../src/BitSafeEvmAssetBridge.sol";
import {ScheduleUpgrade} from "../../script/manage/BitSafeEvmAssetBridge/ScheduleUpgrade.s.sol";
import {ExecuteUpgrade} from "../../script/manage/BitSafeEvmAssetBridge/ExecuteUpgrade.s.sol";
import {CancelUpgrade} from "../../script/manage/BitSafeEvmAssetBridge/CancelUpgrade.s.sol";
import {DeployImplementation} from "../../script/manage/BitSafeEvmAssetBridge/DeployImplementation.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// The five addresses that every upgrade dummy pins. A test sets them once,
/// so no dummy reads a deployment record.
struct Fixture {
    address timelock;
    address proxyAdmin;
    address proxy;
    address nextImplementation;
    address safe;
}

/// Each dummy fixes its deployment name at configure time. A test function
/// names its own deployment, so no two test functions read or write one file.
/// forge runs test functions in parallel, and a shared path would corrupt them.
contract DummySchedule is ScheduleUpgrade {
    Fixture private _f;
    string private _name;

    function configure(Fixture memory f, string memory name) external {
        _f = f;
        _name = name;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function timelock() public view override returns (address) {
        return _f.timelock;
    }

    function proxyAdmin() public view override returns (address) {
        return _f.proxyAdmin;
    }

    function proxy() public view override returns (address) {
        return _f.proxy;
    }

    function nextImplementation() public view override returns (address) {
        return _f.nextImplementation;
    }

    function safeAddress() internal view override returns (address) {
        return _f.safe;
    }
}

contract DummyExecute is ExecuteUpgrade {
    Fixture private _f;
    string private _name;

    function configure(Fixture memory f, string memory name) external {
        _f = f;
        _name = name;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function timelock() public view override returns (address) {
        return _f.timelock;
    }

    function proxyAdmin() public view override returns (address) {
        return _f.proxyAdmin;
    }

    function proxy() public view override returns (address) {
        return _f.proxy;
    }

    function nextImplementation() public view override returns (address) {
        return _f.nextImplementation;
    }

    function safeAddress() internal view override returns (address) {
        return _f.safe;
    }
}

contract DummyCancel is CancelUpgrade {
    Fixture private _f;
    string private _name;

    function configure(Fixture memory f, string memory name) external {
        _f = f;
        _name = name;
    }

    function deploymentName() public view override returns (string memory) {
        return _name;
    }

    function timelock() public view override returns (address) {
        return _f.timelock;
    }

    function proxyAdmin() public view override returns (address) {
        return _f.proxyAdmin;
    }

    function proxy() public view override returns (address) {
        return _f.proxy;
    }

    function nextImplementation() public view override returns (address) {
        return _f.nextImplementation;
    }

    function safeAddress() internal view override returns (address) {
        return _f.safe;
    }
}

/// Pins the deployment name, so the test needs no DEPLOYMENT variable. Only
/// ONE test function uses it, because it writes a pending file.
contract DummyDeployImplementation is DeployImplementation {
    function deploymentName() public pure override returns (string memory) {
        return "UPGDEPLOYIMPL";
    }
}

contract UpgradeActionsTest is BridgeTestBase {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// Bit 2 of the state bitmap names OperationState.Ready.
    bytes32 internal constant READY_STATE = bytes32(uint256(1 << 2));
    uint256 internal constant DELAY = 1 hours;

    TimelockController internal timelock;
    address internal timelockProxyAdmin;
    address internal timelockProxy;
    BitSafeEvmAssetBridge internal oldImpl;
    BitSafeEvmAssetBridge internal nextImpl;
    address internal safe = makeAddr("safe");
    Fixture internal fixture;

    /// The fixture mirrors the deploy script: the timelock owns the
    /// ProxyAdmin, and the Safe is the sole proposer, canceller and executor.
    function setUp() public override {
        super.setUp();

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        oldImpl = new BitSafeEvmAssetBridge();
        bytes memory initData = abi.encodeCall(
            BitSafeEvmAssetBridge.initialize,
            (
                address(0),
                DEFAULT_TARGET_DECIMALS,
                defaultAdmin,
                ADMIN_DELAY,
                bridgeAdmin,
                attestors,
                THRESHOLD,
                BitSafeEvmAssetBridge.Limits({minAmount: 0, maxAmount: type(uint256).max}),
                BitSafeEvmAssetBridge.Limits({minAmount: 0, maxAmount: type(uint256).max})
            )
        );
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(address(oldImpl), address(timelock), initData);
        timelockProxy = address(p);
        timelockProxyAdmin = address(uint160(uint256(vm.load(timelockProxy, ADMIN_SLOT))));
        nextImpl = new BitSafeEvmAssetBridge();

        fixture = Fixture({
            timelock: address(timelock),
            proxyAdmin: timelockProxyAdmin,
            proxy: timelockProxy,
            nextImplementation: address(nextImpl),
            safe: safe
        });
    }

    /// Writes the implementation record that the deployment guard reads.
    function _writeImplRecord(string memory name) private {
        string memory key = string.concat(name, "impl");
        vm.serializeUint(key, "chainId", uint256(31337));
        vm.serializeString(key, "contractName", "BitSafeEvmAssetBridge");
        vm.writeJson(
            vm.serializeAddress(key, "address", timelockProxy),
            string.concat("deployments/", name, ".implementation.31337.json")
        );
    }

    function _removeImplRecord(string memory name) private {
        vm.removeFile(string.concat("deployments/", name, ".implementation.31337.json"));
    }

    function _envelopePath(string memory name, string memory action) private pure returns (string memory) {
        return string.concat("deployments/.safe/", name, ".31337.", action, ".json");
    }

    function _schedule(string memory name) private returns (DummySchedule s) {
        s = new DummySchedule();
        s.configure(fixture, name);
        s.run("");
        vm.removeFile(_envelopePath(name, "scheduleUpgrade"));
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function test_schedule_revertsForANonProposer() public {
        string memory name = "UPGSCHEDNOROLE";
        _writeImplRecord(name);
        Fixture memory f = fixture;
        f.safe = user;
        DummySchedule s = new DummySchedule();
        s.configure(f, name);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, timelock.PROPOSER_ROLE()
            )
        );
        s.run("");
        _removeImplRecord(name);
    }

    function test_schedule_fromTheSafeWritesAnEnvelopeToTheTimelock() public {
        string memory name = "UPGSCHED";
        _writeImplRecord(name);
        DummySchedule s = new DummySchedule();
        s.configure(fixture, name);
        s.run("");

        bytes32 id = s.operationId(address(nextImpl), "");
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertEq(timelock.getTimestamp(id), block.timestamp + DELAY);

        // The envelope goes to the timelock, never to the ProxyAdmin. The
        // Safe holds no role on the ProxyAdmin, so a direct call would fail.
        string memory path = _envelopePath(name, "scheduleUpgrade");
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".to"), address(timelock));
        assertEq(vm.parseJsonAddress(json, ".safe"), safe);
        assertEq(vm.parseJsonString(json, ".action"), "scheduleUpgrade");
        assertEq(vm.parseJsonString(json, ".deployment"), name);
        assertEq(vm.parseJsonBytes(json, ".data"), s.encode(address(nextImpl), ""));
        vm.removeFile(path);
        _removeImplRecord(name);
    }

    function test_execute_revertsBeforeTheDelayPasses() public {
        string memory name = "UPGEXECEARLY";
        _writeImplRecord(name);
        DummySchedule s = _schedule(name);
        bytes32 id = s.operationId(address(nextImpl), "");

        DummyExecute e = new DummyExecute();
        e.configure(fixture, name);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, READY_STATE)
        );
        e.run("");

        assertEq(_implementationOf(timelockProxy), address(oldImpl), "the proxy must not change");
        assertFalse(vm.exists(_envelopePath(name, "executeUpgrade")));
        _removeImplRecord(name);
    }

    function test_execute_afterTheDelayUpgradesTheProxy() public {
        string memory name = "UPGEXEC";
        _writeImplRecord(name);
        DummySchedule s = _schedule(name);
        bytes32 id = s.operationId(address(nextImpl), "");
        assertEq(_implementationOf(timelockProxy), address(oldImpl));

        vm.warp(block.timestamp + DELAY);
        DummyExecute e = new DummyExecute();
        e.configure(fixture, name);
        e.run("");

        assertEq(_implementationOf(timelockProxy), address(nextImpl));
        assertTrue(timelock.isOperationDone(id));
        // The bridge keeps its state across the upgrade.
        assertEq(BitSafeEvmAssetBridge(payable(timelockProxy)).threshold(), THRESHOLD);

        string memory path = _envelopePath(name, "executeUpgrade");
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".to"), address(timelock));
        vm.removeFile(path);
        _removeImplRecord(name);
    }

    function test_cancel_removesAPendingOperation() public {
        string memory name = "UPGCANCEL";
        _writeImplRecord(name);
        DummySchedule s = _schedule(name);
        bytes32 id = s.operationId(address(nextImpl), "");
        assertTrue(timelock.isOperationPending(id));

        DummyCancel c = new DummyCancel();
        c.configure(fixture, name);
        c.run("");

        assertFalse(timelock.isOperation(id));
        assertEq(c.encode(address(nextImpl), ""), abi.encodeCall(TimelockController.cancel, (id)));
        vm.removeFile(_envelopePath(name, "cancelUpgrade"));
        _removeImplRecord(name);
    }

    /// The three scripts must name one operation. A salt or a payload that
    /// differed between them would schedule an operation nobody can execute.
    function test_theThreeScriptsAgreeOnTheOperation() public {
        DummySchedule s = new DummySchedule();
        s.configure(fixture, "UPGAGREE");
        DummyExecute e = new DummyExecute();
        e.configure(fixture, "UPGAGREE");
        DummyCancel c = new DummyCancel();
        c.configure(fixture, "UPGAGREE");

        bytes memory data = hex"1234";
        bytes32 id = s.operationId(address(nextImpl), data);
        assertEq(e.operationId(address(nextImpl), data), id);
        assertEq(c.operationId(address(nextImpl), data), id);
        assertEq(
            id,
            timelock.hashOperation(
                timelockProxyAdmin, 0, s.upgradeCall(address(nextImpl), data), bytes32(0), s.salt(address(nextImpl))
            )
        );
        // The salt binds the deployment name. Another name gives another id.
        DummySchedule other = new DummySchedule();
        other.configure(fixture, "UPGOTHER");
        assertTrue(other.operationId(address(nextImpl), data) != id);

        assertEq(s.action(), "scheduleUpgrade");
        assertEq(e.action(), "executeUpgrade");
        assertEq(c.action(), "cancelUpgrade");
    }

    function test_deployImplementation_writesANextImplementationPendingFile() public {
        DummyDeployImplementation d = new DummyDeployImplementation();
        d.run();

        string memory path = "deployments/.pending/UPGDEPLOYIMPL.31337.json";
        string memory json = vm.readFile(path);
        string[] memory roles = vm.parseJsonStringArray(json, ".roles");
        assertEq(roles.length, 1);
        assertEq(roles[0], "nextImplementation");
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        assertTrue(addresses[0].code.length > 0, "the implementation must exist");
        assertEq(vm.parseJsonStringArray(json, ".contractNames")[0], "BitSafeEvmAssetBridge");
        assertEq(vm.parseJsonStringArray(json, ".sourcePaths")[0], "src/BitSafeEvmAssetBridge.sol");
        assertEq(vm.parseJsonString(json, ".broadcastScript"), "DeployImplementation.s.sol");
        assertEq(vm.parseJsonString(json, ".note"), "next implementation, not yet live");
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        vm.removeFile(path);
    }

    function test_deployImplementation_rejectsAnEmptyDeploymentName() public {
        DeployImplementation d = new DeployImplementation();
        // The test runner sets no DEPLOYMENT. The default of vm.envOr is "".
        vm.expectRevert(DeployImplementation.DeploymentNotSet.selector);
        d.deploymentName();
    }
}
