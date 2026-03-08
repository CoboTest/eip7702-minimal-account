// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PackedUserOperation, IEntryPoint, IPaymaster } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VerifyingPaymaster
/// @author CoboTest
/// @notice Production-grade ERC-4337 v0.7 Verifying Paymaster.
///         A designated `verifyingSigner` (hot wallet) authorizes gas sponsorship per-UserOp.
///         Owner (cold wallet) manages signer rotation, deposits, and stake.
///
/// @dev Security features:
///   - EIP-712 typed data signing with domain separator (chain + paymaster bound)
///   - Replay protection: domain separator includes chainId + paymaster address;
///     hash includes EntryPoint-provided userOpHash (binds calldata + gas + nonce)
///   - Signer/owner separation: owner = admin (cold), verifyingSigner = authorizer (hot)
///   - Ownable2Step: two-step ownership transfer to prevent accidental loss
///   - Pausable: emergency circuit breaker
///   - ReentrancyGuard: defense-in-depth on external calls
///   - postOp accounting hook for future token-based repayment
contract VerifyingPaymaster is IPaymaster, Ownable2Step, Pausable, ReentrancyGuard {
    // ═══════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev EIP-712 domain typehash
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 struct typehash for paymaster authorization.
    ///      Binds signatures to the exact EntryPoint-provided userOpHash to prevent
    ///      payload/gas "bait-and-switch" after sponsorship approval.
    bytes32 public constant PAYMASTER_DATA_TYPEHASH =
        keccak256("PaymasterData(bytes32 userOpHash,uint48 validUntil,uint48 validAfter)");

    /// @dev Cached domain separator (recomputed on chain fork via _domainSeparator())
    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;

    // ═══════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════

    IEntryPoint public immutable entryPoint;

    /// @notice The signer authorized to approve gas sponsorship.
    ///         Can be rotated by owner without redeploying.
    address public verifyingSigner;

    // ═══════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event StakeAdded(uint256 amount, uint32 unstakeDelaySec);
    event StakeUnlocked();
    event StakeWithdrawn(address indexed to);

    // ═══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════

    error OnlyEntryPoint();
    error InvalidEntryPoint();
    error InvalidSignerAddress();
    error InvalidPaymasterDataLength();
    error InsufficientDeposit();

    // ═══════════════════════════════════════════════════════════════════
    //                          MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier onlyEP() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    /// @param _ep EntryPoint v0.7 address
    /// @param _owner Owner (cold wallet) — manages signer, deposits, stake
    /// @param _signer Initial verifying signer (hot wallet) — signs UserOp authorizations
    constructor(
        IEntryPoint _ep,
        address _owner,
        address _signer
    ) Ownable(_owner) {
        if (address(_ep) == address(0)) revert InvalidEntryPoint();
        if (_signer == address(0)) revert InvalidSignerAddress();
        entryPoint = _ep;
        verifyingSigner = _signer;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     EIP-712 DOMAIN
    // ═══════════════════════════════════════════════════════════════════

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256("VerifyingPaymaster"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /// @dev Returns the domain separator, recomputing if chainId changed (fork protection).
    function _domainSeparator() internal view returns (bytes32) {
        if (block.chainid == _cachedChainId) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator();
    }

    /// @notice Returns the EIP-712 domain separator for off-chain signature construction.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     HASH HELPERS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Computes the hash that the verifyingSigner must sign.
    /// @dev Exposed for off-chain tooling to construct signatures.
    ///      `paymasterUserOpHash` must be computed with paymasterAndData excluding
    ///      the trailing 65-byte paymaster signature to avoid circular dependency.
    function getHash(
        bytes32 paymasterUserOpHash,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            PAYMASTER_DATA_TYPEHASH,
            paymasterUserOpHash,
            validUntil,
            validAfter
        ));
        return MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     IPaymaster
    // ═══════════════════════════════════════════════════════════════════

    /// @dev paymasterAndData layout (full array, absolute offsets):
    ///   [0:20]   paymaster address
    ///   [20:36]  pmVerificationGasLimit (uint128)
    ///   [36:52]  pmPostOpGasLimit (uint128)
    ///   [52:58]  validUntil (uint48, 6 bytes)
    ///   [58:64]  validAfter (uint48, 6 bytes)
    ///   [64:129] signature  (65 bytes: r[32] + s[32] + v[1])
    /// Code below slices from [52:] to skip the first 52 bytes.
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 /* maxCost */
    ) external onlyEP whenNotPaused returns (bytes memory context, uint256 validationData) {
        bytes calldata pmData = userOp.paymasterAndData[52:];
        if (pmData.length != 77) revert InvalidPaymasterDataLength(); // 6+6+65

        uint48 validUntil = uint48(bytes6(pmData[0:6]));
        uint48 validAfter = uint48(bytes6(pmData[6:12]));
        bytes calldata signature = pmData[12:77];

        // EIP-712 typed hash — includes chainId + paymaster address via domain separator.
        // Binds the UserOp payload/gas/nonce while excluding the trailing paymaster
        // signature bytes to avoid circular dependency.
        bytes32 paymasterUserOpHash = _getPaymasterUserOpHash(userOp);
        bytes32 hash = getHash(paymasterUserOpHash, validUntil, validAfter);

        address recovered = ECDSA.recover(hash, signature);
        bool sigValid = (recovered == verifyingSigner);

        validationData = _packValidation(sigValid, validAfter, validUntil);
        context = "";
    }

    /// @dev Post-operation hook. Reserved for future token repayment logic.
    function postOp(
        PostOpMode,
        bytes calldata,
        uint256,
        uint256
    ) external onlyEP {}

    // ═══════════════════════════════════════════════════════════════════
    //                     SIGNER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Rotate the verifying signer. Owner only.
    /// @param newSigner New signer address (must not be zero)
    function setVerifyingSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSignerAddress();
        address oldSigner = verifyingSigner;
        verifyingSigner = newSigner;
        emit SignerChanged(oldSigner, newSigner);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     DEPOSIT & STAKE
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposit ETH to EntryPoint for gas sponsorship. Anyone can deposit.
    function deposit() external payable {
        entryPoint.depositTo{ value: msg.value }(address(this));
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraw deposit from EntryPoint. Owner only.
    function withdrawTo(address payable to, uint256 amount) external onlyOwner nonReentrant {
        entryPoint.withdrawTo(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Add stake to EntryPoint. Owner only.
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{ value: msg.value }(unstakeDelaySec);
        emit StakeAdded(msg.value, unstakeDelaySec);
    }

    /// @notice Unlock stake (starts unstake delay). Owner only.
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
        emit StakeUnlocked();
    }

    /// @notice Withdraw stake after delay. Owner only.
    function withdrawStake(address payable to) external onlyOwner nonReentrant {
        entryPoint.withdrawStake(to);
        emit StakeWithdrawn(to);
    }

    /// @notice Get current deposit in EntryPoint.
    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     EMERGENCY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pause — blocks validatePaymasterUserOp. Owner only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause. Owner only.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     INTERNALS
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Computes EntryPoint-style userOpHash, but with paymasterAndData excluding
    ///      the trailing 65-byte paymaster signature.
    function _getPaymasterUserOpHash(PackedUserOperation calldata userOp) internal view returns (bytes32) {
        bytes calldata paymasterAndDataNoSig = userOp.paymasterAndData[:64]; // 20+16+16+6+6

        bytes32 packHash = keccak256(abi.encode(
            userOp.sender,
            userOp.nonce,
            keccak256(userOp.initCode),
            keccak256(userOp.callData),
            userOp.accountGasLimits,
            userOp.preVerificationGas,
            userOp.gasFees,
            keccak256(paymasterAndDataNoSig)
        ));

        return keccak256(abi.encode(packHash, address(entryPoint), block.chainid));
    }

    /// @dev Pack ERC-4337 validationData: [validAfter:6][validUntil:6][authorizer:20]
    function _packValidation(
        bool success,
        uint48 validAfter,
        uint48 validUntil
    ) internal pure returns (uint256) {
        uint160 authorizer = success ? 0 : 1;
        return uint256(validAfter) << 208 | uint256(validUntil) << 160 | authorizer;
    }

    /// @dev Accept ETH directly (e.g. from EntryPoint refunds).
    receive() external payable {}
}
