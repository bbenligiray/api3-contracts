// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./vendor/@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import "@api3/airnode-protocol-v1/contracts/utils/ExtendedSelfMulticall.sol";
import "./interfaces/IAirseekerRegistry.sol";
import "./vendor/@openzeppelin/contracts@4.9.5/utils/structs/EnumerableSet.sol";
import "@api3/airnode-protocol-v1/contracts/api3-server-v1/interfaces/IApi3ServerV1.sol";

/// @title A contract that is used by its owner to register the data required
/// by an Airseeker to uphold the respective data feed specs
/// @notice Airseeker is an application that pushes API provider-signed data to
/// chain when certain conditions are met so that the data feeds served on the
/// Api3ServerV1 contract are updated according to the respective specs. In
/// other words, this contract can be thought of as an on-chain configuration
/// file for an Airseeker (or multiple Airseekers with redundancy).
/// The Airseeker must know which data feeds are active (and thus need to be
/// updated), the constituting Airnode (the oracle node that API providers
/// operate to sign data) addresses and request template IDs, what the
/// respective on-chain data feed values are, what the update parameters are,
/// and the URL of the signed APIs (from which Airseeker can fetch signed data)
/// that are hosted by the respective API providers.
contract AirseekerRegistry is
    Ownable,
    ExtendedSelfMulticall,
    IAirseekerRegistry
{
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Maximum number of Beacons that a Beacon set whose details are
    /// being registered can consist of
    /// @dev A Beacon is identified by an Airnode address and a request
    /// template ID, which means it is a single-source data feed. Multiple
    /// Beacons can be aggregated on-chain to create a multiple-source data
    /// feed, which is called a Beacon set. This conract does not support
    /// Beacon sets that consist of more than `MAXIMUM_BEACON_COUNT_IN_SET`
    /// Beacons. In the context of a first-party oracle solution, this is the
    /// maximum number of API providers.
    uint256 public constant override MAXIMUM_BEACON_COUNT_IN_SET = 21;

    /// @notice Api3ServerV1 contract address
    address public immutable override api3ServerV1;

    /// @notice Airnode address to signed API URL
    /// @dev The signed APIs must implement the specific interface that
    /// Airseeker expects. Refer to https://github.com/api3dao/signed-api for
    /// an example implementation.
    /// The signed APIs must be hosted by the operator of the respective
    /// Airnode (i.e., the API provider) for a trust-minimized architecture.
    mapping(address => string) public override airnodeToSignedApiUrl;

    /// @notice Data feed ID to encoded details
    /// @dev See the `registerDataFeed()` implementation for details
    mapping(bytes32 => bytes) public override dataFeedIdToDetails;

    // Api3ServerV1 uses Beacon IDs (see the `deriveBeaconId()` implementation)
    // and Beacon set IDs (see the `deriveBeaconSetId()` implementation) to
    // address data feeds. We use data feed ID as a general term to refer to a
    // Beacon or Beacon set ID.
    // A data feed ID is immutable. Api3ServerV1 allows a dAPI name to be
    // pointed to a data feed ID to implement a mutable data feed addressing
    // scheme.
    // If the data feed ID or dAPI name should be used to read a data feed
    // depends on the use case. To support both schemes, AirseekerRegistry
    // allows data feeds specs to be defined with either the data feed ID or
    // the dAPI name.
    EnumerableSet.Bytes32Set private activeDataFeedIds;

    EnumerableSet.Bytes32Set private activeDapiNames;

    // Considering that the update parameters are typically reused, a hash map
    // is used to avoid storing the same update parameters redundantly
    mapping(bytes32 => bytes32) private dataFeedIdToUpdateParametersHash;

    mapping(bytes32 => bytes32) private dapiNameToUpdateParametersHash;

    mapping(bytes32 => bytes) private updateParametersHashToValue;

    // Length of abi.encode(address, bytes32)
    uint256 private constant DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON =
        32 + 32;

    // Length of abi.encode(address[2], bytes32[2])
    uint256
        private constant DATA_FEED_DETAILS_LENGTH_FOR_BEACON_SET_WITH_TWO_BEACONS =
        (2 * 32) + (32 + 2 * 32) + (32 + 2 * 32);

    // Length of
    // abi.encode(address[MAXIMUM_BEACON_COUNT_IN_SET], bytes32[MAXIMUM_BEACON_COUNT_IN_SET])
    uint256 private constant MAXIMUM_DATA_FEED_DETAILS_LENGTH =
        (2 * 32) +
            (32 + MAXIMUM_BEACON_COUNT_IN_SET * 32) +
            (32 + MAXIMUM_BEACON_COUNT_IN_SET * 32);

    /// @dev Reverts if the data feed ID is zero
    /// @param dataFeedId Data feed ID
    modifier onlyNonZeroDataFeedId(bytes32 dataFeedId) {
        require(dataFeedId != bytes32(0), "Data feed ID zero");
        _;
    }

    /// @dev Reverts if the dAPI name is zero
    /// @param dapiName dAPI name
    modifier onlyNonZeroDapiName(bytes32 dapiName) {
        require(dapiName != bytes32(0), "dAPI name zero");
        _;
    }

    /// @param owner_ Owner address
    /// @param api3ServerV1_ Api3ServerV1 contract address
    constructor(address owner_, address api3ServerV1_) {
        require(owner_ != address(0), "Owner address zero");
        require(api3ServerV1_ != address(0), "Api3ServerV1 address zero");
        _transferOwnership(owner_);
        api3ServerV1 = api3ServerV1_;
    }

    /// @notice Returns the owner address
    /// @return Owner address
    function owner() public view override(Ownable, IOwnable) returns (address) {
        return super.owner();
    }

    /// @notice Overriden to be disabled
    function renounceOwnership() public pure override(IOwnable, Ownable) {
        revert("Ownership cannot be renounced");
    }

    /// @notice Overriden to be disabled
    function transferOwnership(
        address
    ) public pure override(IOwnable, Ownable) {
        revert("Ownership cannot be transferred");
    }

    function setDataFeedIdToBeActivated(
        bytes32 dataFeedId
    ) external override onlyOwner onlyNonZeroDataFeedId(dataFeedId) {
        if (activeDataFeedIds.add(dataFeedId)) {
            emit ActivatedDataFeedId(dataFeedId);
        }
    }

    function setDapiNameToBeActivated(
        bytes32 dapiName
    ) external override onlyOwner onlyNonZeroDapiName(dapiName) {
        if (activeDapiNames.add(dapiName)) {
            emit ActivatedDapiName(dapiName);
        }
    }

    function setDataFeedIdToBeDeactivated(
        bytes32 dataFeedId
    ) external override onlyOwner onlyNonZeroDataFeedId(dataFeedId) {
        if (activeDataFeedIds.remove(dataFeedId)) {
            emit DeactivatedDataFeedId(dataFeedId);
        }
    }

    function setDapiNameToBeDeactivated(
        bytes32 dapiName
    ) external override onlyOwner onlyNonZeroDapiName(dapiName) {
        if (activeDapiNames.remove(dapiName)) {
            emit DeactivatedDapiName(dapiName);
        }
    }

    function setDataFeedIdUpdateParameters(
        bytes32 dataFeedId,
        bytes calldata updateParameters
    ) external override onlyOwner onlyNonZeroDataFeedId(dataFeedId) {
        // Set update parameters maximum length
        bytes32 updateParametersHash = keccak256(updateParameters);
        if (
            dataFeedIdToUpdateParametersHash[dataFeedId] != updateParametersHash
        ) {
            dataFeedIdToUpdateParametersHash[dataFeedId] = updateParametersHash;
            if (
                keccak256(updateParametersHashToValue[updateParametersHash]) !=
                updateParametersHash
            ) {
                updateParametersHashToValue[
                    updateParametersHash
                ] = updateParameters;
            }
            emit UpdatedDataFeedIdUpdateParameters(
                dataFeedId,
                updateParameters
            );
        }
    }

    function setDapiNameUpdateParameters(
        bytes32 dapiName,
        bytes calldata updateParameters
    ) external override onlyOwner onlyNonZeroDapiName(dapiName) {
        bytes32 updateParametersHash = keccak256(updateParameters);
        if (dapiNameToUpdateParametersHash[dapiName] != updateParametersHash) {
            dapiNameToUpdateParametersHash[dapiName] = updateParametersHash;
            if (
                keccak256(updateParametersHashToValue[updateParametersHash]) !=
                updateParametersHash
            ) {
                updateParametersHashToValue[
                    updateParametersHash
                ] = updateParameters;
            }
            emit UpdatedDapiNameUpdateParameters(dapiName, updateParameters);
        }
    }

    function setSignedApiUrl(
        address airnode,
        string calldata signedApiUrl
    ) external override onlyOwner {
        require(airnode != address(0), "Airnode address zero");
        require(
            abi.encodePacked(signedApiUrl).length <= 256,
            "Signed API URL too long"
        );
        if (
            keccak256(abi.encodePacked(airnodeToSignedApiUrl[airnode])) !=
            keccak256(abi.encodePacked(signedApiUrl))
        ) {
            airnodeToSignedApiUrl[airnode] = signedApiUrl;
            emit UpdatedSignedApiUrl(airnode, signedApiUrl);
        }
    }

    function registerDataFeed(
        bytes calldata dataFeedDetails
    ) external override returns (bytes32 dataFeedId) {
        uint256 dataFeedDetailsLength = dataFeedDetails.length;
        if (
            dataFeedDetailsLength == DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON
        ) {
            // dataFeedId maps to a Beacon
            (address airnode, bytes32 templateId) = abi.decode(
                dataFeedDetails,
                (address, bytes32)
            );
            require(airnode != address(0), "Airnode address zero");
            dataFeedId = deriveBeaconId(airnode, templateId);
        } else if (
            dataFeedDetailsLength >=
            DATA_FEED_DETAILS_LENGTH_FOR_BEACON_SET_WITH_TWO_BEACONS
        ) {
            // dataFeedId maps to a Beacon set with at least two Beacons.
            require(
                dataFeedDetailsLength <= MAXIMUM_DATA_FEED_DETAILS_LENGTH,
                "Feed details data too long"
            );
            (address[] memory airnodes, bytes32[] memory templateIds) = abi
                .decode(dataFeedDetails, (address[], bytes32[]));
            require(
                abi.encode(airnodes, templateIds).length ==
                    dataFeedDetailsLength,
                "Feed details data trail"
            );
            uint256 beaconCount = airnodes.length;
            require(
                beaconCount == templateIds.length,
                "Parameter length mismatch"
            );
            bytes32[] memory beaconIds = new bytes32[](beaconCount);
            for (uint256 ind = 0; ind < beaconCount; ind++) {
                require(airnodes[ind] != address(0), "Airnode address zero");
                beaconIds[ind] = deriveBeaconId(
                    airnodes[ind],
                    templateIds[ind]
                );
            }
            dataFeedId = deriveBeaconSetId(beaconIds);
        } else {
            revert("Details data too short");
        }
        if (
            keccak256(dataFeedIdToDetails[dataFeedId]) !=
            keccak256(dataFeedDetails)
        ) {
            dataFeedIdToDetails[dataFeedId] = dataFeedDetails;
            emit RegisteredDataFeed(dataFeedId, dataFeedDetails);
        }
    }

    // The owner of this contract is responsible with registering
    // `dataFeedDetails` and setting `updateParameters` for data feeds that it
    // will activate. In the case that an Airseeker fetches an active data feed
    // with empty `dataFeedDetails` and/or `updateParameters` that cannot be
    // parsed, it should skip it.
    // `dapiName` will only be `bytes32(0)` when the active data feed is
    // identified by a data feed ID and not a dAPI name.
    // In general, this function makes a best effort attempt at retrieving all
    // data related to an active data feed, even if the returned data may not
    // be enough for the intended use-case of being a source of reference for
    // Airseeker.
    function activeDataFeed(
        uint256 index
    )
        external
        view
        override
        returns (
            bytes32 dataFeedId,
            bytes32 dapiName,
            bytes memory dataFeedDetails,
            int224 dataFeedValue,
            uint32 dataFeedTimestamp,
            int224[] memory beaconValues,
            uint32[] memory beaconTimestamps,
            bytes memory updateParameters,
            string[] memory signedApiUrls
        )
    {
        uint256 activeDataFeedIdsLength = activeDataFeedIdCount();
        if (index < activeDataFeedIdsLength) {
            dataFeedId = activeDataFeedIds.at(index);
            updateParameters = dataFeedIdToUpdateParameters(dataFeedId);
        } else if (index < activeDataFeedIdsLength + activeDapiNames.length()) {
            dapiName = activeDapiNames.at(index - activeDataFeedIdsLength);
            dataFeedId = IApi3ServerV1(api3ServerV1).dapiNameHashToDataFeedId(
                keccak256(abi.encodePacked(dapiName))
            );
            updateParameters = dapiNameToUpdateParameters(dapiName);
        }
        if (dataFeedId != bytes32(0)) {
            dataFeedDetails = dataFeedIdToDetails[dataFeedId];
            (dataFeedValue, dataFeedTimestamp) = IApi3ServerV1(api3ServerV1)
                .dataFeeds(dataFeedId);
        }
        if (dataFeedDetails.length != 0) {
            if (
                dataFeedDetails.length ==
                DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON
            ) {
                beaconValues = new int224[](1);
                beaconTimestamps = new uint32[](1);
                signedApiUrls = new string[](1);
                (address airnode, bytes32 templateId) = abi.decode(
                    dataFeedDetails,
                    (address, bytes32)
                );
                (beaconValues[0], beaconTimestamps[0]) = IApi3ServerV1(
                    api3ServerV1
                ).dataFeeds(deriveBeaconId(airnode, templateId));
                signedApiUrls[0] = airnodeToSignedApiUrl[airnode];
            } else {
                (address[] memory airnodes, bytes32[] memory templateIds) = abi
                    .decode(dataFeedDetails, (address[], bytes32[]));
                uint256 beaconCount = airnodes.length;
                beaconValues = new int224[](beaconCount);
                beaconTimestamps = new uint32[](beaconCount);
                signedApiUrls = new string[](beaconCount);
                for (uint256 ind = 0; ind < beaconCount; ind++) {
                    (beaconValues[ind], beaconTimestamps[ind]) = IApi3ServerV1(
                        api3ServerV1
                    ).dataFeeds(
                            deriveBeaconId(airnodes[ind], templateIds[ind])
                        );
                    signedApiUrls[ind] = airnodeToSignedApiUrl[airnodes[ind]];
                }
            }
        }
    }

    function activeDataFeedCount() external view override returns (uint256) {
        return activeDataFeedIdCount() + activeDapiNameCount();
    }

    function activeDataFeedIdCount() public view override returns (uint256) {
        return activeDataFeedIds.length();
    }

    function activeDapiNameCount() public view override returns (uint256) {
        return activeDapiNames.length();
    }

    // Returns "" if the update parameters are not set. The user should be
    // recommended to compare the returned value with the used hash.
    function dataFeedIdToUpdateParameters(
        bytes32 dataFeedId
    ) public view override returns (bytes memory updateParameters) {
        updateParameters = updateParametersHashToValue[
            dataFeedIdToUpdateParametersHash[dataFeedId]
        ];
    }

    // Returns "" if the update parameters are not set. The user should be
    // recommended to compare the returned value with the used hash.
    function dapiNameToUpdateParameters(
        bytes32 dapiName
    ) public view override returns (bytes memory updateParameters) {
        updateParameters = updateParametersHashToValue[
            dapiNameToUpdateParametersHash[dapiName]
        ];
    }

    // This is cheaper to use than fetching the entire details and checking its
    // length
    function dataFeedIsRegistered(
        bytes32 dataFeedId
    ) external view override returns (bool) {
        return dataFeedIdToDetails[dataFeedId].length != 0;
    }

    function deriveBeaconId(
        address airnode,
        bytes32 templateId
    ) private pure returns (bytes32 beaconId) {
        beaconId = keccak256(abi.encodePacked(airnode, templateId));
    }

    function deriveBeaconSetId(
        bytes32[] memory beaconIds
    ) private pure returns (bytes32 beaconSetId) {
        beaconSetId = keccak256(abi.encode(beaconIds));
    }
}
