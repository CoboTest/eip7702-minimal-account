// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAccount } from "./interfaces/IAccount.sol";
import { PackedUserOperation } from "./interfaces/PackedUserOperation.sol";
import { IERC165 } from "./interfaces/IERC165.sol";

/// @title MinimalAccount
/// @notice Minimal EIP-7702 delegate contract for EOAs.
///         Provides batch execution and ERC-4337 gas sponsorship.
///         No owner storage, no initialize — EOA private key is the sole authority.
/// @dev    Designed to be set as an EOA's delegate via EIP-7702 authorization.
///         Validates signatures against `address(this)` (the EOA itself).
///         Compatible with ERC-7821 Minimal Batch Executor interface.
///
///         SECURITY: All external calls use `call` only — no `delegatecall`.
///         This prevents storage corruption from untrusted targets.
///         Self-calls are explicitly blocked to prevent re-entrant
///         privilege escalation (e.g., calling validateUserOp on itself).
///
///         TRUST MODEL: This contract trusts the ERC-4337 v0.7 EntryPoint singleton
///         at 0x0000000071727De22E5E9d8BAf0edAc6f37da032. The EntryPoint is allowed
///         to call execute/executeBatch after validating the UserOp via validateUserOp.
///         This is safe because the EntryPoint guarantees it will only execute the
///         UserOp's callData after a successful validation (signature check).
///         Note: Under EIP-7702, the EOA can revoke or replace this delegation at any
///         time via a new type-4 authorization. This does not affect the EntryPoint
///         trust assumption — it simply means the delegation code may no longer be active.
contract MinimalAccount is IAccount {
    // ─── Errors ──────────────────────────────────────────────────────────

    /// @dev Caller is not this account (the EOA) or the EntryPoint.
    error Unauthorized();

    /// @dev Caller is not the EntryPoint.
    error OnlyEntryPoint();

    /// @dev A call in the batch failed.
    error ExecutionFailed(uint256 index, bytes returnData);

    /// @dev Cannot call self in a batch (prevents privilege escalation).
    error SelfCallNotAllowed();

    /// @dev Prefund transfer to EntryPoint failed (insufficient balance).
    error PrefundFailed();

    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice ERC-4337 v0.7 EntryPoint (singleton).
    address public constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @dev ERC-4337 validationData: signature is valid (no time range restriction).
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;

    /// @dev ERC-4337 validationData: signature validation failed.
    ///      Maps to SIG_VALIDATION_FAILED sentinel in EntryPoint v0.7.
    uint256 private constant SIG_VALIDATION_FAILED = 1;

    // ─── Structs ─────────────────────────────────────────────────────────

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    // ─── Events ──────────────────────────────────────────────────────────

    event BatchExecuted(uint256 indexed count);
    event Executed(address indexed target, uint256 value);

    // ─── Modifiers ───────────────────────────────────────────────────────

    /// @dev Only the EOA itself or the EntryPoint can call.
    modifier onlySelfOrEntryPoint() {
        if (msg.sender != address(this) && msg.sender != ENTRY_POINT) {
            revert Unauthorized();
        }
        _;
    }

    /// @dev Only the EntryPoint can call.
    modifier onlyEntryPoint() {
        if (msg.sender != ENTRY_POINT) {
            revert OnlyEntryPoint();
        }
        _;
    }

    // ─── External Functions ──────────────────────────────────────────────

    /// @notice Execute a batch of calls.
    /// @dev    Only callable by the EOA itself (via direct tx) or EntryPoint (via UserOp).
    ///         Reverts if any call targets this contract (self-call prevention).
    /// @param calls Array of calls to execute sequentially.
    function executeBatch(Call[] calldata calls) external payable onlySelfOrEntryPoint {
        uint256 len = calls.length;
        for (uint256 i; i < len; ) {
            Call calldata c = calls[i];
            if (c.target == address(this)) revert SelfCallNotAllowed();
            (bool ok, bytes memory ret) = c.target.call{ value: c.value }(c.data);
            if (!ok) revert ExecutionFailed(i, ret);
            emit Executed(c.target, c.value);
            unchecked { ++i; }
        }
        emit BatchExecuted(len);
    }

    /// @notice Execute a single call (convenience).
    /// @dev    Reverts if target is this contract (self-call prevention).
    /// @param target Target contract address.
    /// @param value  ETH value to send.
    /// @param data   Calldata to send.
    /// @return result The return data from the call.
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable onlySelfOrEntryPoint returns (bytes memory result) {
        if (target == address(this)) revert SelfCallNotAllowed();
        bool ok;
        (ok, result) = target.call{ value: value }(data);
        if (!ok) revert ExecutionFailed(0, result);
        emit Executed(target, value);
    }

    // ─── ERC-4337 IAccount ───────────────────────────────────────────────

    /// @notice Validate a UserOperation signature for ERC-4337 gas sponsorship.
    /// @dev    Only callable by the EntryPoint (per ERC-4337 spec).
    ///         Validates that the signature was produced by the EOA's private key
    ///         (i.e., `ecrecover` returns `address(this)`).
    ///         NOTE: We do not check `userOp.sender == address(this)` because the
    ///         EntryPoint guarantees it only calls validateUserOp on the sender account.
    /// @param userOp         The packed user operation.
    /// @param userOpHash     Hash of the user operation.
    /// @param missingAccountFunds Funds the account must deposit to EntryPoint.
    /// @return validationData 0 if valid, 1 if invalid (SIG_VALIDATION_FAILED).
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // Validate signature against the EOA address (address(this))
        validationData = _validateSignature(userOpHash, userOp.signature)
            ? SIG_VALIDATION_SUCCESS
            : SIG_VALIDATION_FAILED;

        // Pay prefund only if signature is valid.
        // If invalid, return SIG_VALIDATION_FAILED without reverting —
        // let EntryPoint handle rejection gracefully.
        if (missingAccountFunds > 0 && validationData == SIG_VALIDATION_SUCCESS) {
            (bool ok, ) = payable(ENTRY_POINT).call{ value: missingAccountFunds }("");
            if (!ok) revert PrefundFailed();
        }
    }

    // ─── ERC-165 ─────────────────────────────────────────────────────────

    /// @notice ERC-165 interface support.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IAccount).interfaceId ||  // ERC-4337
            interfaceId == type(IERC165).interfaceId;     // ERC-165
    }

    // ─── Receive ETH ────────────────────────────────────────────────────

    receive() external payable {}

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Validate an ECDSA signature against the EOA's own address.
    ///      Wraps the hash with EIP-191 personal_sign prefix to prevent
    ///      blind-signing attacks (user sees the hash in wallet UI).
    /// @param hash The userOpHash from EntryPoint.
    /// @param signature The 65-byte ECDSA signature (r, s, v) over the EIP-191 prefixed hash.
    /// @return valid True if the recovered signer matches this account.
    function _validateSignature(
        bytes32 hash,
        bytes calldata signature
    ) internal view returns (bool valid) {
        if (signature.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        // Reject malleable signatures (EIP-2 / OpenZeppelin convention)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return false;
        }

        // EIP-191 prefix: forces personal_sign in wallet UI,
        // preventing blind-signing of raw UserOp hashes
        bytes32 prefixedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
        );

        address recovered = ecrecover(prefixedHash, v, r, s);
        return recovered != address(0) && recovered == address(this);
    }
}
