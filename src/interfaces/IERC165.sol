// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev See https://eips.ethereum.org/EIPS/eip-165
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
