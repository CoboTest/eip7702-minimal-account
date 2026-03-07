// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Account } from "@openzeppelin/contracts/account/Account.sol";
import { SignerEIP7702 } from "@openzeppelin/contracts/utils/cryptography/signers/SignerEIP7702.sol";
import { ERC7821 } from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { IAccount, IEntryPoint, PackedUserOperation } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { IERC7821 } from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ERC4337Utils } from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title MinimalAccount
/// @notice EIP-7702 delegate contract for EOAs using OpenZeppelin's Account stack.
///         Provides ERC-7821 batch execution and ERC-4337 gas sponsorship.
/// @dev    Uses Account + SignerEIP7702 + ERC7821.
///         SignerEIP7702 validates raw ECDSA signatures against address(this).
///         ERC7821 provides execute(bytes32 mode, bytes executionData) with ERC-7579 encoding.
///         Overrides entryPoint() to use v0.7, _signableUserOpHash to add EIP-191 prefix,
///         and _erc7821AuthorizedExecutor to allow EntryPoint.
contract MinimalAccount is Account, SignerEIP7702, ERC7821, ERC721Holder, ERC1155Holder {
    /// @dev Override to use ERC-4337 v0.7 EntryPoint.
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return ERC4337Utils.ENTRYPOINT_V07;
    }

    /// @dev Wrap userOpHash with EIP-191 prefix for v0.7 (non-EIP-712 hash).
    ///      Follows eth-infinitism SimpleAccount convention.
    ///      Client must use personal_sign(userOpHash) instead of raw signing.
    function _signableUserOpHash(
        PackedUserOperation calldata, /* userOp */
        bytes32 userOpHash
    ) internal view virtual override returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(userOpHash);
    }

    /// @dev Register IAccount, IERC7821, and IERC721Receiver interface IDs.
    ///      IERC1155Receiver is covered by super via ERC1155Holder.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccount).interfaceId
            || interfaceId == type(IERC7821).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId); // includes IERC1155Receiver from ERC1155Holder
    }

    /// @dev Allow EntryPoint to call execute() in addition to self (default).
    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 mode,
        bytes calldata executionData
    ) internal view virtual override returns (bool) {
        return caller == address(entryPoint()) || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
