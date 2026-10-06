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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";

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
    using RateLimiter for RateLimiter.RefillingBucket;

    /// Both bounds are inclusive. An amount passes when
    /// `minAmount <= amount <= maxAmount`, so `minAmount == maxAmount` names
    /// exactly one legal amount.
    struct Limits {
        uint256 minAmount; // 0 = no minimum. An amount of 0 still reverts with ZeroAmount.
        uint256 maxAmount; // type(uint256).max = no maximum. No uint256 exceeds it.
    }

    bytes32 public constant BRIDGE_ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant SENTRY_ROLE = keccak256("SENTRY_ROLE");
    uint256 public constant MIN_THRESHOLD = 2;
    /// @dev 18 is the idiomatic maximum precision for an ERC20.
    uint8 public constant MAX_ASSET_DECIMALS = 18;
    /// @dev Canton's CIP-56 token standard sets 10 as the maximum precision. This
    ///      bridge targets Canton, so it accepts no higher value.
    uint8 public constant MAX_TARGET_DECIMALS = 10;
    /// @dev ETH has no contract to ask, so its precision is a convention.
    uint8 private constant ETH_DECIMALS = 18;
    bytes32 public constant WITHDRAWAL_TYPEHASH =
        keccak256("Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount,uint256 deadline)");
    /// @dev The bridge rate-limits all withdrawals as one flow, so one
    ///      constant key selects a single global bucket.
    bytes32 private constant WITHDRAW_RATE_LIMIT_KEY = bytes32(0);

    /// @custom:storage-location erc7201:bitsafe.storage.BitSafeEvmAssetBridge
    struct BridgeStorage {
        address asset;
        uint8 assetDecimals;
        uint8 targetDecimals;
        uint256 threshold;
        Limits depositLimits;
        Limits withdrawLimits;
        EnumerableSet.AddressSet attestors;
        mapping(bytes withdrawRequestId => bool used) usedWithdrawRequests;
        // Bounds the withdrawal rate with a token bucket that refills
        // linearly at `capacity / window` per second. A capacity of 0 turns
        // the check off.
        RateLimiter.RefillingBucket withdrawRateLimit;
        uint256 totalLocked;
        uint256 withdrawalHorizon;
    }

    // cast index-erc7201 bitsafe.storage.BitSafeEvmAssetBridge
    bytes32 public constant BRIDGE_STORAGE_LOCATION =
        0xe9e5dc9730c787910ca70d94c5f8cdb143fd0b13ee96336e56e945dc2a3d2500;

    event Deposit(bytes32 indexed depositAccountIdHash, bytes depositAccountId, address indexed sender, uint256 amount);
    event Withdraw(
        bytes32 indexed withdrawRequestIdHash,
        bytes withdrawRequestId,
        address indexed destinationAddress,
        uint256 amount,
        uint256 deadline
    );
    event WithdrawRequestVoided(bytes32 indexed withdrawRequestIdHash, bytes withdrawRequestId);
    event AttestorSetChanged(address[] attestors, uint256 threshold);
    event ThresholdSet(uint256 newThreshold);
    event DepositLimitsSet(uint256 minAmount, uint256 maxAmount);
    event WithdrawLimitsSet(uint256 minAmount, uint256 maxAmount);
    event WithdrawRateLimitSet(uint208 capacity, uint48 window);
    event WithdrawalHorizonSet(uint256 horizon);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);
    event SurplusRescued(address indexed to, uint256 amount);

    error InvalidAddress();
    error InvalidLimits();
    error DecimalsOutOfRange();
    error ThresholdOutOfBounds();
    error EmptyId();
    error ZeroAmount();
    error AmountOutsideLimits(uint256 amount, uint256 minAmount, uint256 maxAmount);
    error AmountNotRepresentable(uint256 amount, uint256 depositUnit);
    error AssetIsNotEther();
    error AssetIsNotERC20();
    error WithdrawRequestAlreadyUsed();
    error WithdrawalExpired(uint256 deadline);
    error DeadlineBeyondHorizon(uint256 deadline, uint256 horizon);
    error InvalidDestination();
    error NotEnoughSignatures();
    error AttestorCannotRenounce();
    error NotPauser(address caller);
    error UnexpectedBalanceChange();
    error CannotRescueBridgedAsset();
    error AmountExceedsSurplus(uint256 amount, uint256 surplus);
    error EthTransferFailed();
    error DirectEthTransferNotAllowed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        uint8 targetDecimals_,
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
        _setDecimals(targetDecimals_);

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

    function assetDecimals() external view returns (uint8) {
        return _getBridgeStorage().assetDecimals;
    }

    /// @notice Decimal places the target chain expresses. Canton expresses 10.
    function targetDecimals() external view returns (uint8) {
        return _getBridgeStorage().targetDecimals;
    }

    /// @notice The smallest deposit step the target chain can express, in asset
    ///         base units. Every deposit amount must be a whole multiple of it.
    function depositUnit() external view returns (uint256) {
        return _depositUnit(_getBridgeStorage());
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

    /// @notice The withdrawal rate limit: the shared configuration and the
    ///         budget that is available now. A capacity of 0 means the check
    ///         is off - `availableBudget` reads 0 then, but nothing limits
    ///         withdrawals.
    function withdrawRateLimit() external view returns (uint208 capacity, uint48 window, uint256 availableBudget) {
        RateLimiter.RefillingBucket storage limiter = _getBridgeStorage().withdrawRateLimit;
        capacity = limiter._capacity;
        window = limiter._window;
        availableBudget = limiter.available(WITHDRAW_RATE_LIMIT_KEY);
    }

    /// @notice The maximum distance a withdrawal `deadline` can sit past
    ///         `block.timestamp`, in seconds (inclusive). `0` turns the bound
    ///         off.
    function withdrawalHorizon() external view returns (uint256) {
        return _getBridgeStorage().withdrawalHorizon;
    }

    function getAttestors() external view returns (address[] memory) {
        return _getBridgeStorage().attestors.values();
    }

    function isWithdrawRequestUsed(bytes calldata withdrawRequestId) external view returns (bool) {
        return _getBridgeStorage().usedWithdrawRequests[withdrawRequestId];
    }

    function totalLocked() external view returns (uint256) {
        return _getBridgeStorage().totalLocked;
    }

    /// @notice Bridged-asset balance above `totalLocked`: funds no deposit
    ///         backs, such as forced-in ETH or direct token transfers.
    function surplus() public view returns (uint256) {
        BridgeStorage storage $ = _getBridgeStorage();
        address asset_ = $.asset;
        uint256 balance = asset_ == address(0) ? address(this).balance : IERC20(asset_).balanceOf(address(this));
        uint256 tl = $.totalLocked;
        // Clamps to 0: a counter above the balance reports no surplus.
        return balance > tl ? balance - tl : 0;
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

    /// @notice A sentry or the bridge admin pauses. Only the bridge admin unpauses.
    /// @dev A sentry key may be hot: the role grants only a denial power, and the
    ///      admin can always reverse it.
    function pause() external {
        if (!hasRole(BRIDGE_ADMIN_ROLE, msg.sender) && !hasRole(SENTRY_ROLE, msg.sender)) {
            revert NotPauser(msg.sender);
        }
        _pause();
    }

    function unpause() external onlyRole(BRIDGE_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice The default admin sets the threshold. The threshold and the
    ///         attestor set together define how many operators must agree, so
    ///         one role owns both.
    function setThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setThreshold(newThreshold, _getBridgeStorage().attestors.length());
    }

    function setDepositLimits(Limits calldata newLimits) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _setDepositLimits(newLimits);
    }

    function setWithdrawLimits(Limits calldata newLimits) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _setWithdrawLimits(newLimits);
    }

    /// @notice Sets the withdrawal rate limit: a token bucket with a maximum
    ///         of `capacity` base units that refills at `capacity / window`
    ///         per second. A `capacity` of 0 disables the check.
    /// @dev A `window` of 0 with a non-zero `capacity` reverts: the library
    ///      treats it as 1 second, which refills the whole bucket every
    ///      second and silently turns the limit off. New settings do not
    ///      reset the bucket's use, so a lowered capacity acts immediately.
    function setWithdrawRateLimit(uint208 capacity, uint48 window) external onlyRole(BRIDGE_ADMIN_ROLE) {
        if (capacity != 0 && window == 0) revert InvalidLimits();
        BridgeStorage storage $ = _getBridgeStorage();
        // Freeze the debt under the old settings before they change. Without
        // the sync, updateSettings re-prices the elapsed time at the new
        // rate, and a window change grants a full bucket at once.
        $.withdrawRateLimit.sync(WITHDRAW_RATE_LIMIT_KEY);
        $.withdrawRateLimit.updateSettings(window, capacity);
        emit WithdrawRateLimitSet(capacity, window);
    }

    /// @notice Sets the withdrawal horizon: the maximum distance a withdrawal
    ///         `deadline` can sit past `block.timestamp`, in seconds. The
    ///         bound is inclusive. `0` disables the bound.
    function setWithdrawalHorizon(uint256 horizon) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _getBridgeStorage().withdrawalHorizon = horizon;
        emit WithdrawalHorizonSet(horizon);
    }

    /// @notice Rescues tokens sent to the bridge by mistake. Never the bridged asset.
    /// @dev The reentrancy guard is transient and shared across all guarded
    ///      functions, so a guarded function cannot nest inside another
    ///      guarded call.
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(BRIDGE_ADMIN_ROLE) nonReentrant {
        if (token == _getBridgeStorage().asset) revert CannotRescueBridgedAsset();
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Rescues stray ETH (for example forced in via selfdestruct). Never the bridged asset.
    ///         Only callable when the bridged asset is not ETH.
    function rescueETH(address to, uint256 amount) external onlyRole(BRIDGE_ADMIN_ROLE) nonReentrant {
        if (_getBridgeStorage().asset == address(0)) revert CannotRescueBridgedAsset();
        if (to == address(0)) revert InvalidAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ETHRescued(to, amount);
    }

    /// @notice Rescues the bridged-asset balance above `totalLocked`, such as
    ///         forced-in ETH or direct token transfers. The only rescue path
    ///         that touches the bridged asset, and the counter bounds it:
    ///         deposited funds stay out of reach.
    function rescueSurplus(address to, uint256 amount) external onlyRole(BRIDGE_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        uint256 surplus_ = surplus();
        if (amount > surplus_) revert AmountExceedsSurplus(amount, surplus_);
        address asset_ = _getBridgeStorage().asset;
        if (asset_ == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset_).safeTransfer(to, amount);
        }
        emit SurplusRescued(to, amount);
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

    /// @dev Reads the asset's own decimals and stores both precisions.
    function _setDecimals(uint8 targetDecimals_) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        address asset_ = $.asset;
        uint8 assetDecimals_ = asset_ == address(0) ? ETH_DECIMALS : IERC20Metadata(asset_).decimals();
        // The asset sits in 1 to MAX_ASSET_DECIMALS, because it is an EVM token.
        if (assetDecimals_ == 0 || assetDecimals_ > MAX_ASSET_DECIMALS) revert DecimalsOutOfRange();
        // The target sits in 1 to MAX_TARGET_DECIMALS, which Canton's CIP-56
        // standard sets. A deployment for another chain needs a new bound here.
        if (targetDecimals_ == 0 || targetDecimals_ > MAX_TARGET_DECIMALS) revert DecimalsOutOfRange();
        $.assetDecimals = assetDecimals_;
        $.targetDecimals = targetDecimals_;
    }

    /// @dev Returns 1 when the target expresses at least as many places as the
    ///      asset. Every amount is then representable and the check is inert.
    function _depositUnit(BridgeStorage storage $) internal view returns (uint256) {
        uint8 assetDecimals_ = $.assetDecimals;
        uint8 targetDecimals_ = $.targetDecimals;
        if (targetDecimals_ >= assetDecimals_) return 1;
        return 10 ** (assetDecimals_ - targetDecimals_);
    }

    /// @dev Draws `amount` from the withdrawal rate limit and reverts with
    ///      the library's RateLimitExceeded when the bucket holds less. A
    ///      capacity of 0 turns the check off: the library reports an
    ///      uninitialized bucket as empty, so without this gate a zero
    ///      config would block every withdrawal instead of none.
    function _consumeWithdrawRateLimit(BridgeStorage storage $, uint256 amount) internal {
        RateLimiter.RefillingBucket storage limiter = $.withdrawRateLimit;
        if (limiter._capacity == 0) return;
        limiter.consume(WITHDRAW_RATE_LIMIT_KEY, amount);
    }

    /// @dev Reverts when `deadline` sits further than `horizon` past
    ///      `block.timestamp`. The bound is inclusive:
    ///      `deadline == block.timestamp + horizon` passes. A horizon of 0
    ///      turns the check off.
    function _checkHorizon(uint256 horizon, uint256 deadline) internal view {
        if (horizon != 0 && deadline > block.timestamp + horizon) {
            revert DeadlineBeyondHorizon(deadline, horizon);
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
        BridgeStorage storage $ = _getBridgeStorage();
        // The band must hold at least one amount the target chain can express.
        uint256 unit = _depositUnit($);
        uint256 largestValidAmount = (newLimits.maxAmount / unit) * unit;
        // The first clause is the only guard when `minAmount` is 0, because
        // `0 < 0` is false. Keep both.
        if (largestValidAmount == 0 || largestValidAmount < newLimits.minAmount) revert InvalidLimits();
        $.depositLimits = newLimits;
        emit DepositLimitsSet(newLimits.minAmount, newLimits.maxAmount);
    }

    function _setWithdrawLimits(Limits calldata newLimits) internal {
        _validateLimits(newLimits);
        _getBridgeStorage().withdrawLimits = newLimits;
        emit WithdrawLimitsSet(newLimits.minAmount, newLimits.maxAmount);
    }

    /// @dev Enforces two rules: the maximum is above 0, and the minimum is at or
    ///      below the maximum. A zero maximum would reject every amount, so it is
    ///      always a misconfiguration. `pause` is the tool for blocking traffic.
    ///      Neither sentinel needs a special case, because 0 is at or below every
    ///      amount and `type(uint256).max` is at or above every amount.
    function _validateLimits(Limits calldata limits) internal pure {
        if (limits.maxAmount == 0 || limits.minAmount > limits.maxAmount) revert InvalidLimits();
    }

    // -------------------------------------------------------------- deposits

    /// @notice Locks ETH for the Canton deposit account named by depositAccountId.
    function depositETH(bytes calldata depositAccountId) external payable whenNotPaused {
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.asset != address(0)) revert AssetIsNotEther();
        _validateDeposit(depositAccountId, msg.value, $);
        $.totalLocked += msg.value;
        emit Deposit(keccak256(depositAccountId), depositAccountId, msg.sender, msg.value);
    }

    /// @notice Locks the configured ERC20 asset. Requires prior approval.
    function depositERC20(uint256 amount, bytes calldata depositAccountId) external whenNotPaused nonReentrant {
        BridgeStorage storage $ = _getBridgeStorage();
        address asset_ = $.asset;
        if (asset_ == address(0)) revert AssetIsNotERC20();
        _validateDeposit(depositAccountId, amount, $);
        uint256 balanceBefore = IERC20(asset_).balanceOf(address(this));
        IERC20(asset_).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(asset_).balanceOf(address(this)) - balanceBefore != amount) {
            revert UnexpectedBalanceChange();
        }
        // After the balance-delta check: the counter records confirmed amounts only.
        $.totalLocked += amount;
        // Emitted after the transfer: the amount is only confirmed by the balance-delta check above.
        emit Deposit(keccak256(depositAccountId), depositAccountId, msg.sender, amount);
    }

    function _validateDeposit(bytes calldata depositAccountId, uint256 amount, BridgeStorage storage $) internal view {
        if (depositAccountId.length == 0) revert EmptyId();
        if (amount == 0) revert ZeroAmount();
        _checkLimits(amount, $.depositLimits);
        // The target chain must be able to express the minted amount. Without
        // this check the remainder below its precision would be unmintable.
        uint256 unit = _depositUnit($);
        if (amount % unit != 0) revert AmountNotRepresentable(amount, unit);
    }

    receive() external payable {
        revert DirectEthTransferNotAllowed();
    }

    fallback() external payable {
        revert DirectEthTransferNotAllowed();
    }

    // ----------------------------------------------------------- withdrawals

    /// @notice The exact EIP-712 digest attestors must sign for a withdrawal.
    function withdrawalDigest(
        bytes calldata withdrawRequestId,
        address destinationAddress,
        uint256 amount,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(WITHDRAWAL_TYPEHASH, keccak256(withdrawRequestId), destinationAddress, amount, deadline)
            )
        );
    }

    /// @notice Releases `amount` of the bridged asset to `destinationAddress`.
    /// @dev Requires `threshold` valid, distinct attestor signatures over the
    ///      EIP-712 digest. Signer order does not matter. A malformed,
    ///      non-attestor or duplicate signature does not count.
    ///      The attestor stack derives the deadline when it signs.
    function withdraw(
        bytes calldata withdrawRequestId,
        address destinationAddress,
        uint256 amount,
        uint256 deadline,
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
        _consumeWithdrawRateLimit($, amount);
        // Inclusive bound: the bundle stays valid through the deadline second.
        if (block.timestamp > deadline) revert WithdrawalExpired(deadline);
        _checkHorizon($.withdrawalHorizon, deadline);
        if (signatures.length < threshold_) revert NotEnoughSignatures();

        bytes32 digest = withdrawalDigest(withdrawRequestId, destinationAddress, amount, deadline);
        if (_countAttestorSigners(digest, signatures) < threshold_) revert NotEnoughSignatures();

        // Effect before interaction: consume the request id.
        $.usedWithdrawRequests[withdrawRequestId] = true;
        // Canton cannot burn more BETH than it minted, so a legitimate
        // `amount` never exceeds `totalLocked`. The checked subtraction
        // reverts on a drifted counter instead of paying unbacked funds.
        $.totalLocked -= amount;

        // Interaction.
        address asset_ = $.asset;
        if (asset_ == address(0)) {
            (bool ok,) = destinationAddress.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(asset_).safeTransfer(destinationAddress, amount);
        }
        emit Withdraw(keccak256(withdrawRequestId), withdrawRequestId, destinationAddress, amount, deadline);
    }

    /// @dev Counts the distinct current attestors that signed `digest`. A
    ///      malformed, non-attestor or duplicate signature does not count, but
    ///      it does not revert either: one misconfigured attestor must not
    ///      block a bundle that still carries `threshold` valid signatures.
    function _countAttestorSigners(bytes32 digest, bytes[] calldata signatures) private view returns (uint256 count) {
        address[] memory signers = new address[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signatures[i]);
            if (err != ECDSA.RecoverError.NoError || signer == address(0)) continue;
            if (!hasRole(ATTESTOR_ROLE, signer)) continue;
            bool duplicate;
            for (uint256 j; j < count && !duplicate; ++j) {
                duplicate = signers[j] == signer;
            }
            if (!duplicate) signers[count++] = signer;
        }
    }

    /// @notice Marks `withdrawRequestId` used without paying it, so no signed
    ///         `Withdrawal` bundle for that id can ever execute.
    /// @dev Void the id before the attestors confirm the matching Canton
    ///      cancel; see the README section "Voiding a withdraw request".
    ///      Not `whenNotPaused` on purpose: the void must work during an
    ///      incident pause.
    function voidWithdrawRequest(bytes calldata withdrawRequestId) external onlyRole(BRIDGE_ADMIN_ROLE) {
        BridgeStorage storage $ = _getBridgeStorage();
        if (withdrawRequestId.length == 0) revert EmptyId();
        if ($.usedWithdrawRequests[withdrawRequestId]) revert WithdrawRequestAlreadyUsed();
        $.usedWithdrawRequests[withdrawRequestId] = true;
        emit WithdrawRequestVoided(keccak256(withdrawRequestId), withdrawRequestId);
    }
}
