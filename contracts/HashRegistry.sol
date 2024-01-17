// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./vendor/@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import "./interfaces/IHashRegistry.sol";
import "./vendor/@openzeppelin/contracts@4.9.5/utils/cryptography/ECDSA.sol";

contract HashRegistry is Ownable, IHashRegistry {
    using ECDSA for bytes32;

    struct Hash {
        bytes32 value;
        uint256 timestamp;
    }

    mapping(bytes32 => Hash) public override hashes;

    mapping(bytes32 => bytes32) public override hashTypeToSignersHash;

    constructor(address owner_) {
        transferOwnership(owner_);
    }

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

    function registerHash(
        bytes32 hashType,
        bytes32 hash,
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
            signers[ind] = (
                keccak256(abi.encodePacked(hashType, hash, timestamp))
                    .toEthSignedMessageHash()
            ).recover(signatures[ind]);
        }
        require(
            signersHash == keccak256(abi.encodePacked(signers)),
            "Signature mismatch"
        );
        hashes[hashType] = Hash({value: hash, timestamp: timestamp});
        emit RegisteredHash(hashType, hash, timestamp);
    }

    // External contracts can already read the hash `(value, timestamp)` by
    // calling `hashes()`. However, this is not ideal because in most cases
    // only the hash value will be needed, but the caller will have to pay the
    // gas cost of reading both the value and timestamp. This function
    // implements an alternative interface that does not suffer from this
    // issue.
    // We do not need this anywhere in this repo because Api3Market inherits
    // HashRegistry. This function is implemented only for potential, future
    // use-cases of this contract.
    function getHashValue(
        bytes32 hashType
    ) external view override returns (bytes32 value) {
        value = hashes[hashType].value;
    }
}
