// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//   ___  ____  _  _  ___  ____  __
//  / __)(  _ \( \/ )(  _ \(_  _)/  \
// ( (__  )   / \  /  )___/  )(  (  O )
//  \___)(_)\_) (__) (__)   (__)  \__/
//
/// @title Crypto
/// @author @taayyohh
/// @notice Inlined cryptographic primitives for Praxis contracts
/// @dev Minimal subset of OpenZeppelin's ECDSA, EIP-712, and MerkleProof libraries.
///      Inlined to keep the contract dependency surface minimal — these primitives
///      are well-audited patterns from openzeppelin/contracts v5.x. Do not modify
///      without re-running differential tests against the OZ originals.

/// @notice ECDSA signature recovery with canonical-s rejection
/// @dev Rejects malleable signatures by requiring `s` in the lower half of the curve
library ECDSA {
    error InvalidSignature();
    error InvalidSignatureLength();
    error InvalidSignatureS();

    /// @notice Recover the signer of an EIP-191 personal_sign message
    /// @param hash The 32-byte hash that was signed
    /// @param signature 65-byte signature (r || s || v)
    /// @return signer The recovered address
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        // Reject signatures with `s` in the upper half of the curve order to prevent
        // signature malleability (per EIP-2). secp256k1 lower half: 0 < s <= n/2
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignatureS();
        }

        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }
}

/// @notice EIP-712 typed-structured-data hashing helpers
/// @dev Minimal implementation — supports a fixed (name, version) at construction time
contract EIP712 {
    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _hashedName;
    bytes32 private immutable _hashedVersion;
    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;
    address private immutable _cachedThis;

    constructor(string memory name, string memory version) {
        _hashedName = keccak256(bytes(name));
        _hashedVersion = keccak256(bytes(version));
        _cachedChainId = block.chainid;
        _cachedThis = address(this);
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _hashedName, _hashedVersion, block.chainid, address(this)));
    }

    /// @notice Get the domain separator for the current chain
    /// @dev Re-computes if chainId or contract address changed (e.g. CREATE2 redeploy on a fork)
    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _cachedChainId && address(this) == _cachedThis) {
            return _cachedDomainSeparator;
        }
        return _buildDomainSeparator();
    }

    /// @notice Hash a struct under EIP-712 with the contract's domain separator
    /// @param structHash The keccak256 hash of the encoded struct
    /// @return digest The full EIP-712 typed data digest ready for signing/recovery
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32 digest) {
        bytes32 sep = _domainSeparatorV4();
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, hex"1901")
            mstore(add(ptr, 0x02), sep)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }
}

/// @notice Merkle tree proof verification
/// @dev Uses sorted-pair hashing so proofs work regardless of left/right ordering
library MerkleProof {
    /// @notice Verify a Merkle proof against a known root
    /// @param proof Array of sibling hashes from leaf to root
    /// @param root The expected root hash
    /// @param leaf The leaf hash being proven
    /// @return True if the proof is valid
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            // Sort the pair before hashing — order-independent proofs
            if (computed < sibling) {
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                computed = keccak256(abi.encodePacked(sibling, computed));
            }
        }
        return computed == root;
    }
}
