// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BitSafeEvmAssetBridge} from "./BitSafeEvmAssetBridge.sol";

/// @title BitSafeHyperEvmAssetBridge
/// @notice The bridge for HyperEVM. It is BitSafeEvmAssetBridge, and its
///         `withdraw` also refuses the HyperCore system addresses.
/// @dev HyperEVM moves native HYPE sent to 0x2222…2222 into the sender's
///      HyperCore spot account. A token sent to its system address,
///      0x2000…0000 + token index, moves the same way. The bridge is the
///      sender. A payout to one of these addresses therefore succeeds, and
///      the funds stay in the bridge's own HyperCore account. The Hyperliquid
///      docs give users both addresses, so a user can paste one as a
///      destination.
///
///      The contract keeps the base `initialize`. The EIP-712 domain name
///      stays "BitSafeEvmAssetBridge", because the attestors build every
///      payout digest with that name. `eip712Domain()` reports that name.
///
///      The list is fixed in code. No role can change it.
contract BitSafeHyperEvmAssetBridge is BitSafeEvmAssetBridge {
    error ReservedDestination(address destination);

    function _validateDestination(address destination) internal view override {
        super._validateDestination(destination);
        if (_isHyperCoreBridgeAddress(destination)) revert ReservedDestination(destination);
    }

    /// The HYPE system address, or a token system address. Every bridgeable
    /// token index is below 2^32, so the check fixes the top 128 bits.
    function _isHyperCoreBridgeAddress(address a) internal pure returns (bool) {
        return a == 0x2222222222222222222222222222222222222222
            || uint160(a) >> 32 == uint160(0x2000000000000000000000000000000000000000) >> 32;
    }
}
