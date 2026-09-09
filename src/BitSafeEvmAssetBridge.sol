// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title BitSafeEvmAssetBridge
/// @notice Locks one configured asset (ETH or one ERC20) and releases it on
///         attestor-signed EIP-712 withdrawal messages. One instance per asset.
contract BitSafeEvmAssetBridge is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Limits {
        uint256 minAmount; // 0 = no minimum
        uint256 maxAmount; // type(uint256).max = no maximum
    }

    bytes32 public constant BRIDGE_ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    uint256 public constant MIN_THRESHOLD = 2;
    bytes32 public constant WITHDRAWAL_TYPEHASH =
        keccak256("Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount)");

    /// @custom:storage-location erc7201:bitsafe.storage.BitSafeEvmAssetBridge
    struct BridgeStorage {
        address asset;
        uint256 threshold;
        Limits depositLimits;
        Limits withdrawLimits;
        EnumerableSet.AddressSet attestors;
        mapping(bytes withdrawRequestId => bool used) usedWithdrawRequests;
    }

    // cast index-erc7201 bitsafe.storage.BitSafeEvmAssetBridge
    bytes32 public constant BRIDGE_STORAGE_LOCATION =
        0xe9e5dc9730c787910ca70d94c5f8cdb143fd0b13ee96336e56e945dc2a3d2500;

    event Deposit(bytes32 indexed depositAccountIdHash, bytes depositAccountId, address indexed sender, uint256 amount);
    event Withdraw(
        bytes32 indexed withdrawRequestIdHash,
        bytes withdrawRequestId,
        address indexed destinationAddress,
        uint256 amount
    );
    event WithdrawRequestVoided(bytes32 indexed withdrawRequestIdHash, bytes withdrawRequestId);
    event AttestorSetChanged(address[] attestors, uint256 threshold);
    event ThresholdSet(uint256 newThreshold);
    event DepositLimitsSet(uint256 minAmount, uint256 maxAmount);
    event WithdrawLimitsSet(uint256 minAmount, uint256 maxAmount);

    error InvalidAddress();
    error InvalidLimits();
    error ThresholdOutOfBounds();
    error EmptyId();
    error ZeroAmount();
    error AmountOutsideLimits(uint256 amount, uint256 minAmount, uint256 maxAmount);
    error AssetIsNotEther();
    error AssetIsNotERC20();
    error WithdrawRequestAlreadyUsed();
    error InvalidDestination();
    error NotEnoughSignatures();
    error InvalidSignature();
    error DuplicateSigner(address signer);
    error SignerIsNotAttestor(address signer);
    error AttestorCannotRenounce();
    error UnexpectedBalanceChange();
    error CannotRescueBridgedAsset();
    error EthTransferFailed();
    error DirectEthTransferNotAllowed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address defaultAdmin,
        uint48 defaultAdminDelay,
        address bridgeAdmin,
        address[] calldata attestors_,
        uint256 threshold_,
        Limits calldata depositLimits_,
        Limits calldata withdrawLimits_
    ) external initializer {
        __AccessControlDefaultAdminRules_init(defaultAdminDelay, defaultAdmin);
        __Pausable_init();
        __EIP712_init("BitSafeEvmAssetBridge", "1");

        if (bridgeAdmin == address(0)) revert InvalidAddress();
        _grantRole(BRIDGE_ADMIN_ROLE, bridgeAdmin);

        BridgeStorage storage $ = _getBridgeStorage();
        $.asset = asset_;

        for (uint256 i; i < attestors_.length; ++i) {
            if (attestors_[i] == address(0)) revert InvalidAddress();
            // A duplicate grant reports no state change; duplicates must revert.
            if (!_grantRole(ATTESTOR_ROLE, attestors_[i])) revert InvalidAddress();
        }
        _setThreshold(threshold_, $.attestors.length());
        _setDepositLimits(depositLimits_);
        _setWithdrawLimits(withdrawLimits_);
    }

    // ---------------------------------------------------------------- views

    function asset() external view returns (address) {
        return _getBridgeStorage().asset;
    }

    function threshold() external view returns (uint256) {
        return _getBridgeStorage().threshold;
    }

    function depositLimits() external view returns (Limits memory) {
        return _getBridgeStorage().depositLimits;
    }

    function withdrawLimits() external view returns (Limits memory) {
        return _getBridgeStorage().withdrawLimits;
    }

    function getAttestors() external view returns (address[] memory) {
        return _getBridgeStorage().attestors.values();
    }

    function isWithdrawRequestUsed(bytes calldata withdrawRequestId) external view returns (bool) {
        return _getBridgeStorage().usedWithdrawRequests[withdrawRequestId];
    }

    // ------------------------------------------------------- role overrides

    function _grantRole(bytes32 role, address account) internal virtual override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == ATTESTOR_ROLE) {
            BridgeStorage storage $ = _getBridgeStorage();
            $.attestors.add(account);
            emit AttestorSetChanged($.attestors.values(), $.threshold);
        }
    }

    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool revoked) {
        revoked = super._revokeRole(role, account);
        if (revoked && role == ATTESTOR_ROLE) {
            BridgeStorage storage $ = _getBridgeStorage();
            $.attestors.remove(account);
            // Revoking below the threshold is allowed: emergency offboarding
            // wins, withdrawals halt until governance restores the set.
            emit AttestorSetChanged($.attestors.values(), $.threshold);
        }
    }

    // ------------------------------------------------------------- admin

    function pause() external onlyRole(BRIDGE_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(BRIDGE_ADMIN_ROLE) {
        _unpause();
    }

    function setThreshold(uint256 newThreshold) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _setThreshold(newThreshold, _getBridgeStorage().attestors.length());
    }

    function setDepositLimits(Limits calldata newLimits) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _setDepositLimits(newLimits);
    }

    function setWithdrawLimits(Limits calldata newLimits) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _setWithdrawLimits(newLimits);
    }

    /// @notice Rescues tokens sent to the bridge by mistake. Never the bridged asset.
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(BRIDGE_ADMIN_ROLE) {
        if (token == _getBridgeStorage().asset) revert CannotRescueBridgedAsset();
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Rescues stray ETH (for example forced in via selfdestruct).
    ///         Only callable when the bridged asset is not ETH.
    function rescueETH(address to, uint256 amount) external onlyRole(BRIDGE_ADMIN_ROLE) {
        if (_getBridgeStorage().asset == address(0)) revert CannotRescueBridgedAsset();
        if (to == address(0)) revert InvalidAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Attestors leave only through revokeRole.
    function renounceRole(bytes32 role, address callerConfirmation) public virtual override {
        if (role == ATTESTOR_ROLE) revert AttestorCannotRenounce();
        super.renounceRole(role, callerConfirmation);
    }

    // ---------------------------------------------------- internal helpers

    function _getBridgeStorage() internal pure returns (BridgeStorage storage $) {
        assembly {
            $.slot := BRIDGE_STORAGE_LOCATION
        }
    }

    function _checkLimits(uint256 amount, Limits storage limits) internal view {
        if (amount < limits.minAmount || amount > limits.maxAmount) {
            revert AmountOutsideLimits(amount, limits.minAmount, limits.maxAmount);
        }
    }

    function _setThreshold(uint256 newThreshold, uint256 attestorCount) internal {
        if (newThreshold < MIN_THRESHOLD || newThreshold > attestorCount) revert ThresholdOutOfBounds();
        _getBridgeStorage().threshold = newThreshold;
        emit ThresholdSet(newThreshold);
    }

    function _setDepositLimits(Limits calldata newLimits) internal {
        _validateLimits(newLimits);
        _getBridgeStorage().depositLimits = newLimits;
        emit DepositLimitsSet(newLimits.minAmount, newLimits.maxAmount);
    }

    function _setWithdrawLimits(Limits calldata newLimits) internal {
        _validateLimits(newLimits);
        _getBridgeStorage().withdrawLimits = newLimits;
        emit WithdrawLimitsSet(newLimits.minAmount, newLimits.maxAmount);
    }

    function _validateLimits(Limits calldata limits) internal pure {
        if (limits.maxAmount == 0 || limits.minAmount > limits.maxAmount) revert InvalidLimits();
    }

    // -------------------------------------------------------------- deposits

    /// @notice Locks ETH for the Canton deposit account named by depositAccountId.
    function depositETH(bytes calldata depositAccountId) external payable whenNotPaused {
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.asset != address(0)) revert AssetIsNotEther();
        _validateDeposit(depositAccountId, msg.value, $);
        emit Deposit(keccak256(depositAccountId), depositAccountId, msg.sender, msg.value);
    }

    /// @notice Locks the configured ERC20 asset. Requires prior approval.
    function depositERC20(uint256 amount, bytes calldata depositAccountId) external whenNotPaused {
        BridgeStorage storage $ = _getBridgeStorage();
        address asset_ = $.asset;
        if (asset_ == address(0)) revert AssetIsNotERC20();
        _validateDeposit(depositAccountId, amount, $);
        uint256 balanceBefore = IERC20(asset_).balanceOf(address(this));
        IERC20(asset_).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(asset_).balanceOf(address(this)) - balanceBefore != amount) {
            revert UnexpectedBalanceChange();
        }
        // Emitted after the transfer: the amount is only confirmed by the balance-delta check above.
        emit Deposit(keccak256(depositAccountId), depositAccountId, msg.sender, amount);
    }

    function _validateDeposit(bytes calldata depositAccountId, uint256 amount, BridgeStorage storage $) internal view {
        if (depositAccountId.length == 0) revert EmptyId();
        if (amount == 0) revert ZeroAmount();
        _checkLimits(amount, $.depositLimits);
    }

    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    fallback() external payable {
        revert DirectEthTransferNotAllowed();
    }

    // ----------------------------------------------------------- withdrawals

    /// @notice The exact EIP-712 digest attestors must sign for a withdrawal.
    function withdrawalDigest(bytes calldata withdrawRequestId, address destinationAddress, uint256 amount)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(WITHDRAWAL_TYPEHASH, keccak256(withdrawRequestId), destinationAddress, amount))
        );
    }

    /// @notice Releases `amount` of the bridged asset to `destinationAddress`.
    /// @dev Requires `threshold` valid, distinct attestor signatures over the
    ///      EIP-712 digest. Signer order does not matter.
    function withdraw(
        bytes calldata withdrawRequestId,
        address destinationAddress,
        uint256 amount,
        bytes[] calldata signatures
    ) external onlyRole(ATTESTOR_ROLE) whenNotPaused nonReentrant {
        BridgeStorage storage $ = _getBridgeStorage();

        // Checks. A degenerate (zero) threshold must never open the bridge.
        uint256 threshold_ = $.threshold;
        if (threshold_ < MIN_THRESHOLD) revert ThresholdOutOfBounds();
        if (withdrawRequestId.length == 0) revert EmptyId();
        if ($.usedWithdrawRequests[withdrawRequestId]) revert WithdrawRequestAlreadyUsed();
        if (destinationAddress == address(0) || destinationAddress == address(this)) {
            revert InvalidDestination();
        }
        if (amount == 0) revert ZeroAmount();
        _checkLimits(amount, $.withdrawLimits);
        if (signatures.length < threshold_) revert NotEnoughSignatures();

        bytes32 digest = withdrawalDigest(withdrawRequestId, destinationAddress, amount);
        address[] memory seenSigners = new address[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
            if (!hasRole(ATTESTOR_ROLE, signer)) revert SignerIsNotAttestor(signer);
            for (uint256 j; j < i; ++j) {
                if (seenSigners[j] == signer) revert DuplicateSigner(signer);
            }
            seenSigners[i] = signer;
        }

        // Effect before interaction: consume the request id.
        $.usedWithdrawRequests[withdrawRequestId] = true;

        // Interaction.
        address asset_ = $.asset;
        if (asset_ == address(0)) {
            (bool ok,) = destinationAddress.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset_).safeTransfer(destinationAddress, amount);
        }
        emit Withdraw(keccak256(withdrawRequestId), withdrawRequestId, destinationAddress, amount);
    }

    /// @notice Marks `withdrawRequestId` used without paying it, so no signed
    ///         `Withdrawal` bundle for that id can ever execute.
    /// @dev Void the id when a cancel is proposed for the matching Canton
    ///      withdraw request, before the attestors confirm it. The attestors
    ///      confirm only a used id with no `Withdraw` event, and the confirmed
    ///      cancel credits the user back on Canton. A bundle collected earlier
    ///      has no deadline, so only the void makes it unusable. Reverts with
    ///      the same errors as `withdraw` for an empty or already used id, so a
    ///      paid id cannot be voided and a voided id cannot be paid.
    ///      Deliberately NOT `whenNotPaused`: a pause is the response to an
    ///      incident and voiding is part of resolving it, so it must remain
    ///      available while paused. Same role as `pause`; adds no power the
    ///      role lacks.
    function voidWithdrawRequest(bytes calldata withdrawRequestId) external onlyRole(BRIDGE_ADMIN_ROLE) {
        BridgeStorage storage $ = _getBridgeStorage();
        if (withdrawRequestId.length == 0) revert EmptyId();
        if ($.usedWithdrawRequests[withdrawRequestId]) revert WithdrawRequestAlreadyUsed();
        $.usedWithdrawRequests[withdrawRequestId] = true;
        emit WithdrawRequestVoided(keccak256(withdrawRequestId), withdrawRequestId);
    }
}
