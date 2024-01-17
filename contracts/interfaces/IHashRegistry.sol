// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IOwnable.sol";

interface IHashRegistry is IOwnable {
    event SetSigners(bytes32 indexed hashType, address[] signers);

    event RegisteredHash(
        bytes32 indexed hashType,
        bytes32 value,
        uint256 timestamp
    );

    function setSigners(bytes32 hashType, address[] calldata signers) external;

    function registerHash(
        bytes32 hashType,
        bytes32 value,
        uint256 timestamp,
        bytes[] calldata signatures
    ) external;

    function getHashValue(
        bytes32 hashType
    ) external view returns (bytes32 value);

    function hashes(
        bytes32 hashType
    ) external view returns (bytes32 value, uint256 timestamp);

    function hashTypeToSignersHash(
        bytes32 hashType
    ) external view returns (bytes32 signersHash);
}
