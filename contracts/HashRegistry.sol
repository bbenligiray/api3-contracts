// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./vendor/@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import "./interfaces/IHashRegistry.sol";
import "./vendor/@openzeppelin/contracts@4.9.5/utils/cryptography/ECDSA.sol";

/// @title A contract where a value for each hash type can be registered using
/// the signatures of the respective signers that are set by the contract owner
/// @notice Hashes are identified by a unique "hash type", which is a `bytes32`
/// type that can be determined based on any arbitrary convention. The contract
/// owner can set a list of signers for each hash type. For a hash value to be
/// registered, its signers must be set by the contract owner, and valid
/// signatures by each signer must be provided. The hash values are bundled
/// with timestamps that act as nonces, meaning that each registration must
/// be with a larger timestamp than the previous.
/// @dev This contract can be used in standalone form to be referred to through
/// external calls, or inherited by the contract that will access the
/// registered hashes internally
contract HashRegistry is Ownable, IHashRegistry {
    struct Hash {
        bytes32 value;
        uint256 timestamp;
    }

    /// @notice Hash type to the last registered value and timestamp
    mapping(bytes32 => Hash) public override hashes;

    /// @notice Hash type to the hash of the array of signer addresses. This
    /// returning `bytes32(0)` means that the signers have not been set for the
    /// hash type.
    mapping(bytes32 => bytes32) public override hashTypeToSignersHash;

    /// @param owner_ Owner address
    constructor(address owner_) {
        transferOwnership(owner_);
    }

    /// @notice Returns the owner address
    /// @return Owner address
    function owner()
        public
        view
        virtual
        override(Ownable, IOwnable)
        returns (address)
    {
        return super.owner();
    }

    /// @notice Overriden to be disabled
    function renounceOwnership() public virtual override(Ownable, IOwnable) {
        revert("Ownership cannot be renounced");
    }

    /// @notice Transfers the ownership of the contract
    /// @param newOwner New owner address
    function transferOwnership(
        address newOwner
    ) public virtual override(Ownable, IOwnable) {
        super.transferOwnership(newOwner);
    }

    /// @notice Called by the contract owner to set signers for a hash type.
    /// The signer addresses must be in ascending order.
    /// @param hashType Hash type
    /// @param signers Signer addresses
    function setSigners(
        bytes32 hashType,
        address[] calldata signers
    ) external override onlyOwner {
        require(hashType != bytes32(0), "Hash type zero");
        uint256 signersCount = signers.length;
        require(signersCount != 0, "Signers empty");
        require(signers[0] != address(0), "First signer address zero");
        for (uint256 ind = 1; ind < signersCount; ind++) {
            require(
                signers[ind] > signers[ind - 1],
                "Signers not in ascending order"
            );
        }
        hashTypeToSignersHash[hashType] = keccak256(abi.encodePacked(signers));
        emit SetSigners(hashType, signers);
    }

    /// @notice Registers the hash value and timestamp for the respective type.
    /// The timestamp must be smaller than the block timestamp, and larger than
    /// the timestamp of the previous registration.
    /// The signers must have been set for the hash type, and the signatures
    /// must be sorted for the respective signer addresses to be in ascending
    /// order.
    /// @param hashType Hash type
    /// @param value Hash value
    /// @param timestamp Hash timestamp
    /// @param signatures Signatures
    function registerHash(
        bytes32 hashType,
        bytes32 value,
        uint256 timestamp,
        bytes[] calldata signatures
    ) external override {
        require(timestamp <= block.timestamp, "Timestamp from future");
        require(
            timestamp > hashes[hashType].timestamp,
            "Timestamp not more recent"
        );
        bytes32 signersHash = hashTypeToSignersHash[hashType];
        require(signersHash != bytes32(0), "Signers not set");
        uint256 signaturesCount = signatures.length;
        address[] memory signers = new address[](signaturesCount);
        for (uint256 ind = 0; ind < signaturesCount; ind++) {
            signers[ind] = ECDSA.recover(
                ECDSA.toEthSignedMessageHash(
                    keccak256(abi.encodePacked(hashType, value, timestamp))
                ),
                signatures[ind]
            );
        }
        require(
            signersHash == keccak256(abi.encodePacked(signers)),
            "Signature mismatch"
        );
        hashes[hashType] = Hash({value: value, timestamp: timestamp});
        emit RegisteredHash(hashType, value, timestamp);
    }

    /// @notice Called to get the hash value for the type
    /// @param hashType Hash type
    /// @return value Hash value
    function getHashValue(
        bytes32 hashType
    ) external view override returns (bytes32 value) {
        value = hashes[hashType].value;
    }
}
