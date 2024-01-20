// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./HashRegistry.sol";
import "@api3/airnode-protocol-v1/contracts/utils/ExtendedSelfMulticall.sol";
import "./interfaces/IApi3Market.sol";
import "./AirseekerRegistry.sol";
import "./vendor/@openzeppelin/contracts@4.9.5/utils/cryptography/MerkleProof.sol";
import "@api3/airnode-protocol-v1/contracts/api3-server-v1/interfaces/IApi3ServerV1.sol";
import "@api3/airnode-protocol-v1/contracts/api3-server-v1/proxies/interfaces/IProxyFactory.sol";

/// @title The contract that API3 users interact with using the API3 Market
/// frontend to purchase data feed subscriptions
/// @notice API3 aims to streamline and protocolize its sales and integration
/// processes through the API3 Market (https://market.api3.org), which is a
/// data feed subscription marketplace. The Api3Market contract is the on-chain
/// portion of this system.
/// Api3Market enables API3 to predetermine the decisions related to its data
/// feed services (such as the curation of data feed sources or subscription
/// prices) and publish them on-chain. This greatly streamlines the user flow,
/// as it allows the users to initiate subscriptions immediately, without
/// requiring any two-way communication with API3. Furthermore, this removes
/// the need for API3 to have agents operating in the meatspace gathering order
/// details, quoting prices and reviewing payments, and allows all such
/// operations to be cryptographically secured with a multi-party scheme in an
/// end-to-end manner.
/// @dev The user is strongly recommended to use the API3 Market frontend while
/// interacting with this contract, mostly because doing so successfully
/// requires some amount of knowledge of other API3 contracts. Specifically,
/// Api3Market requires the data feed for which the subscription is being
/// purchased to be "readied", the correct Merkle proofs to be provided, and
/// enough payment to be made. The API3 Market frontend will fetch the
/// appropriate Merkle proofs, create a multicall transaction that will ready
/// the data feed before making the call to buy the subscription, and compute
/// the amount to be sent that will barely allow the subscription to be
/// purchased. For most users, building such a transaction themselves would be
/// too impractical.
contract Api3Market is HashRegistry, ExtendedSelfMulticall, IApi3Market {
    enum UpdateParametersComparisonResult {
        EqualToQueued,
        BetterThanQueued,
        WorseThanQueued
    }

    // The update parameters for each subscription is kept in a hash map rather
    // than in long form as an optimization, refer to AirseekerRegistry for a
    // similar implementation.
    // The subscription queues are kept as linked lists, for which each
    // subscription has a next subscription ID.
    struct Subscription {
        bytes32 updateParametersHash;
        uint32 endTimestamp;
        uint224 dailyPrice;
        bytes32 nextSubscriptionId;
    }

    /// @notice Maximum subscription queue length for a dAPI
    /// @dev Some functionality in this contract requires to iterate through
    /// the entire subscription queue for a dAPI, and the queue length is
    /// limited to prevent this process from being bloated. Considering that
    /// each item in the subscription queue has unique update parameters, the
    /// length of the subscription queue is also limited by the number of
    /// unique update parameters offered in the dAPI pricing Merkle tree. For
    /// reference, at the time this contract is implemented, the API3 Market
    /// offers 4 update parameter options, and this number is not expected to
    /// be increased (i.e., we do not expect this queue length limit to be hit
    /// in practice).
    uint256 public constant override MAXIMUM_SUBSCRIPTION_QUEUE_LENGTH = 5;

    /// @notice dAPI management Merkle root hash type
    /// @dev "Hash type" is what HashRegistry uses to address hashes used for
    /// different purposes, refer to it for details
    bytes32 public constant override DAPI_MANAGEMENT_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("dAPI management Merkle root"));

    /// @notice dAPI pricing Merkle root hash type
    bytes32 public constant override DAPI_PRICING_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("dAPI pricing Merkle root"));

    /// @notice Signed API URL Merkle root hash type
    bytes32 public constant override SIGNED_API_URL_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("Signed API URL Merkle root"));

    /// @notice Maximum dAPI update age. This contract cannot be used to set a
    /// dAPI name to a data feed that has not been updated in the last
    /// `MAXIMUM_DAPI_UPDATE_AGE`.
    uint256 public constant override MAXIMUM_DAPI_UPDATE_AGE = 1 days;

    /// @notice Api3ServerV1 contract address
    address public immutable override api3ServerV1;

    /// @notice ProxyFactory contract address
    address public immutable override proxyFactory;

    /// @notice AirseekerRegistry contract address
    address public immutable override airseekerRegistry;

    /// @notice Subscriptions indexed by their IDs
    mapping(bytes32 => Subscription) public override subscriptions;

    /// @notice dAPI name to current subscription ID, which denotes the start
    /// of the subscription queue for the dAPI
    mapping(bytes32 => bytes32) public override dapiNameToCurrentSubscriptionId;

    // Update parameters hash map
    mapping(bytes32 => bytes) private updateParametersHashToValue;

    // Length of abi.encode(address, bytes32)
    uint256 private constant DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON =
        32 + 32;

    // Length of abi.encode(uint256, int224, uint256)
    uint256 private constant UPDATE_PARAMETERS_LENGTH = 32 + 32 + 32;

    /// @dev Deploys its own AirseekerRegistry deterministically. This implies
    /// that Api3Market-specific Airseekers should be operated pointed at this
    /// contract.
    /// @param owner_ Owner address
    /// @param proxyFactory_ ProxyFactory contract address
    constructor(address owner_, address proxyFactory_) HashRegistry(owner_) {
        proxyFactory = proxyFactory_;
        api3ServerV1 = IProxyFactory(proxyFactory_).api3ServerV1();
        airseekerRegistry = address(
            new AirseekerRegistry{salt: bytes32(0)}(address(this), api3ServerV1)
        );
    }

    /// @notice Returns the owner address
    /// @return Owner address
    function owner()
        public
        view
        override(HashRegistry, IOwnable)
        returns (address)
    {
        return super.owner();
    }

    /// @notice Overriden to be disabled
    function renounceOwnership() public pure override(HashRegistry, IOwnable) {
        revert("Ownership cannot be renounced");
    }

    /// @notice Overriden to be disabled
    function transferOwnership(
        address
    ) public pure override(HashRegistry, IOwnable) {
        revert("Ownership cannot be transferred");
    }

    /// @notice Buys subscription and updates the current subscription ID if
    /// necessary. The user is recommended to only interact with this contract
    /// over the API3 Market frontend due to its complexity.
    /// @dev In the case that the subscription being purchased will become the
    /// current one, the respective data feed must be readied before calling
    /// this function.
    /// Enough funds must be sent to put the sponsor wallet balance over its
    /// expected amount after the subscription is bought. Since sponsor wallets
    /// send data feed update transactions, it is not possible to estimate what
    /// their balance will be at the time sent transactions are confirmed. To
    /// avoid transactions being reverted as a result of this, consider sending
    /// some extra.
    /// @param dapiName dAPI name
    /// @param dataFeedId Data feed ID
    /// @param sponsorWallet Sponsor wallet address
    /// @param dapiManagementMerkleData ABI-encoded dAPI management Merkle root
    /// and proof
    /// @param updateParameters Update parameters
    /// @param duration Subscription duration
    /// @param price Subscription price
    /// @param dapiPricingMerkleData ABI-encoded dAPI pricing Merkle root and
    /// proof
    /// @return subscriptionId Subscription ID
    function buySubscription(
        bytes32 dapiName,
        bytes32 dataFeedId,
        address payable sponsorWallet,
        bytes calldata dapiManagementMerkleData,
        bytes calldata updateParameters,
        uint256 duration,
        uint256 price,
        bytes calldata dapiPricingMerkleData
    ) external payable override returns (bytes32 subscriptionId) {
        require(dataFeedId != bytes32(0), "Data feed ID zero");
        require(sponsorWallet != address(0), "Sponsor wallet address zero");
        verifyDapiManagementMerkleProof(
            dapiName,
            dataFeedId,
            sponsorWallet,
            dapiManagementMerkleData
        );
        verifyDapiPricingMerkleProof(
            dapiName,
            updateParameters,
            duration,
            price,
            dapiPricingMerkleData
        );
        subscriptionId = addSubscriptionToQueue(
            dapiName,
            dataFeedId,
            updateParameters,
            duration,
            price
        );
        require(
            sponsorWallet.balance + msg.value >=
                computeExpectedSponsorWalletBalance(dapiName),
            "Insufficient payment"
        );
        emit BoughtSubscription(
            dapiName,
            subscriptionId,
            dataFeedId,
            sponsorWallet,
            updateParameters,
            duration,
            price,
            msg.value
        );
        if (msg.value > 0) {
            (bool success, ) = sponsorWallet.call{value: msg.value}("");
            require(success, "Transfer unsuccessful");
        }
    }

    /// @notice If the current subscription has ended, updates it with the one
    /// that will end next
    /// @dev The fact that there is a current subscription that has ended means
    /// that API3 is providing a service that was not paid for. Therefore, API3
    /// should poll this function for all active dAPI names and call it
    /// whenever it is not going to revert.
    /// @param dapiName dAPI name
    function updateCurrentSubscriptionId(bytes32 dapiName) public override {
        bytes32 currentSubscriptionId = dapiNameToCurrentSubscriptionId[
            dapiName
        ];
        require(
            currentSubscriptionId != bytes32(0),
            "Subscription queue empty"
        );
        require(
            subscriptions[currentSubscriptionId].endTimestamp <=
                block.timestamp,
            "Current subscription not ended"
        );
        _updateCurrentSubscriptionId(dapiName, currentSubscriptionId);
    }

    // For all active dAPIs, our bot should call this whenever it won't revert.
    // It will have to multicall this with the respective
    // `updateBeaconWithSignedData()`, `updateBeaconSetWithBeacons()` and
    // `registerDataFeed()` calls.
    // We're allowing this to be called even when the dAPI is not active.
    function updateDapiName(
        bytes32 dapiName,
        bytes32 dataFeedId,
        address sponsorWallet,
        bytes calldata dapiManagementMerkleData
    ) external override {
        if (dataFeedId != bytes32(0)) {
            require(sponsorWallet != address(0), "Sponsor wallet address zero");
        } else {
            // A zero `dataFeedId` is used to disable a dAPI. In that case, the
            // sponsor wallet address is also expected to be zero.
            require(
                sponsorWallet == address(0),
                "Sponsor wallet address not zero"
            );
        }
        verifyDapiManagementMerkleProof(
            dapiName,
            dataFeedId,
            sponsorWallet,
            dapiManagementMerkleData
        );
        bytes32 currentDataFeedId = IApi3ServerV1(api3ServerV1)
            .dapiNameHashToDataFeedId(keccak256(abi.encodePacked(dapiName)));
        require(currentDataFeedId != dataFeedId, "Does not update dAPI name");
        if (dataFeedId != bytes32(0)) {
            validateDataFeedReadiness(dataFeedId);
        }
        IApi3ServerV1(api3ServerV1).setDapiName(dapiName, dataFeedId);
    }

    // For all active dAPIs, our bot should call this whenever it won't revert
    function updateSignedApiUrl(
        address airnode,
        string calldata signedApiUrl,
        bytes calldata signedApiUrlMerkleData
    ) external override {
        verifySignedApiUrlMerkleProof(
            airnode,
            signedApiUrl,
            signedApiUrlMerkleData
        );
        require(
            keccak256(abi.encodePacked(signedApiUrl)) !=
                keccak256(
                    abi.encodePacked(
                        AirseekerRegistry(airseekerRegistry)
                            .airnodeToSignedApiUrl(airnode)
                    )
                ),
            "Does not update signed API URL"
        );
        AirseekerRegistry(airseekerRegistry).setSignedApiUrl(
            airnode,
            signedApiUrl
        );
    }

    function updateBeaconWithSignedData(
        address airnode,
        bytes32 templateId,
        uint256 timestamp,
        bytes calldata data,
        bytes calldata signature
    ) external override returns (bytes32 beaconId) {
        return
            IApi3ServerV1(api3ServerV1).updateBeaconWithSignedData(
                airnode,
                templateId,
                timestamp,
                data,
                signature
            );
    }

    function updateBeaconSetWithBeacons(
        bytes32[] calldata beaconIds
    ) external override returns (bytes32 beaconSetId) {
        return
            IApi3ServerV1(api3ServerV1).updateBeaconSetWithBeacons(beaconIds);
    }

    function deployDapiProxy(
        bytes32 dapiName,
        bytes calldata metadata
    ) external override returns (address proxyAddress) {
        proxyAddress = IProxyFactory(proxyFactory).deployDapiProxy(
            dapiName,
            metadata
        );
    }

    function deployDapiProxyWithOev(
        bytes32 dapiName,
        address oevBeneficiary,
        bytes calldata metadata
    ) external override returns (address proxyAddress) {
        proxyAddress = IProxyFactory(proxyFactory).deployDapiProxyWithOev(
            dapiName,
            oevBeneficiary,
            metadata
        );
    }

    function registerDataFeed(
        bytes calldata dataFeedDetails
    ) external override returns (bytes32 dataFeedId) {
        dataFeedId = AirseekerRegistry(airseekerRegistry).registerDataFeed(
            dataFeedDetails
        );
    }

    // This is exposed for monitoring
    function computeExpectedSponsorWalletBalance(
        bytes32 dapiName
    ) public view override returns (uint256 expectedSponsorWalletBalance) {
        uint32 startTimestamp = uint32(block.timestamp);
        Subscription storage queuedSubscription;
        for (
            bytes32 queuedSubscriptionId = dapiNameToCurrentSubscriptionId[
                dapiName
            ];
            queuedSubscriptionId != bytes32(0);
            queuedSubscriptionId = queuedSubscription.nextSubscriptionId
        ) {
            queuedSubscription = subscriptions[queuedSubscriptionId];
            uint32 endTimestamp = queuedSubscription.endTimestamp;
            // Skip if the queued subscription has ended
            if (endTimestamp > block.timestamp) {
                // `endTimestamp` is guaranteed to be larger than `startTimestamp`
                expectedSponsorWalletBalance +=
                    ((endTimestamp - startTimestamp) *
                        queuedSubscription.dailyPrice) /
                    1 days;
                startTimestamp = endTimestamp;
            }
        }
    }

    function computeExpectedSponsorWalletBalanceAfterSubscriptionIsAdded(
        bytes32 dapiName,
        bytes calldata updateParameters,
        uint256 duration,
        uint256 price
    ) external view override returns (uint256 expectedSponsorWalletBalance) {
        require(
            updateParameters.length == UPDATE_PARAMETERS_LENGTH,
            "Update parameters length invalid"
        );
        (
            bytes32 subscriptionId,
            uint32 endTimestamp,
            bytes32 previousSubscriptionId,
            bytes32 nextSubscriptionId
        ) = prospectSubscriptionPositionInQueue(
                dapiName,
                updateParameters,
                duration
            );
        uint256 dailyPrice = (price * 1 days) / duration;
        uint32 startTimestamp = uint32(block.timestamp);
        bytes32 queuedSubscriptionId = previousSubscriptionId == bytes32(0)
            ? subscriptionId
            : dapiNameToCurrentSubscriptionId[dapiName];
        for (; queuedSubscriptionId != bytes32(0); ) {
            if (queuedSubscriptionId == subscriptionId) {
                expectedSponsorWalletBalance +=
                    ((endTimestamp - startTimestamp) * dailyPrice) /
                    1 days;
                startTimestamp = endTimestamp;
                queuedSubscriptionId = nextSubscriptionId;
            } else {
                Subscription storage queuedSubscription = subscriptions[
                    queuedSubscriptionId
                ];
                uint32 queuedSubscriptionEndTimestamp = queuedSubscription
                    .endTimestamp;
                // Skip if the queued subscription has ended
                if (queuedSubscriptionEndTimestamp > block.timestamp) {
                    expectedSponsorWalletBalance +=
                        ((queuedSubscriptionEndTimestamp - startTimestamp) *
                            queuedSubscription.dailyPrice) /
                        1 days;
                    startTimestamp = queuedSubscriptionEndTimestamp;
                }
                if (previousSubscriptionId == queuedSubscriptionId) {
                    queuedSubscriptionId = subscriptionId;
                } else {
                    queuedSubscriptionId = queuedSubscription
                        .nextSubscriptionId;
                }
            }
        }
    }

    // This is a convenience function for the market.
    // This also returns the unflushed section of the queue. The user should
    // ignore these if they want to.
    function getDapiData(
        bytes32 dapiName
    )
        external
        view
        override
        returns (
            bytes memory dataFeedDetails,
            int224 dapiValue,
            uint32 dapiTimestamp,
            int224[] memory beaconValues,
            uint32[] memory beaconTimestamps,
            bytes[] memory updateParameters,
            uint32[] memory endTimestamps,
            uint224[] memory dailyPrices
        )
    {
        bytes32 currentDataFeedId = IApi3ServerV1(api3ServerV1)
            .dapiNameHashToDataFeedId(keccak256(abi.encodePacked(dapiName)));
        dataFeedDetails = AirseekerRegistry(airseekerRegistry)
            .dataFeedIdToDetails(currentDataFeedId);
        (dapiValue, dapiTimestamp) = IApi3ServerV1(api3ServerV1).dataFeeds(
            currentDataFeedId
        );
        if (
            dataFeedDetails.length == DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON
        ) {
            beaconValues = new int224[](1);
            beaconTimestamps = new uint32[](1);
            (address airnode, bytes32 templateId) = abi.decode(
                dataFeedDetails,
                (address, bytes32)
            );
            (beaconValues[0], beaconTimestamps[0]) = IApi3ServerV1(api3ServerV1)
                .dataFeeds(deriveBeaconId(airnode, templateId));
        } else {
            (address[] memory airnodes, bytes32[] memory templateIds) = abi
                .decode(dataFeedDetails, (address[], bytes32[]));
            uint256 beaconCount = airnodes.length;
            beaconValues = new int224[](beaconCount);
            beaconTimestamps = new uint32[](beaconCount);
            for (uint256 ind = 0; ind < beaconCount; ind++) {
                (beaconValues[ind], beaconTimestamps[ind]) = IApi3ServerV1(
                    api3ServerV1
                ).dataFeeds(deriveBeaconId(airnodes[ind], templateIds[ind]));
            }
        }
        uint256 queueLength = 0;
        for (
            bytes32 queuedSubscriptionId = dapiNameToCurrentSubscriptionId[
                dapiName
            ];
            queuedSubscriptionId != bytes32(0);
            queuedSubscriptionId = subscriptions[queuedSubscriptionId]
                .nextSubscriptionId
        ) {
            queueLength++;
        }
        updateParameters = new bytes[](queueLength);
        endTimestamps = new uint32[](queueLength);
        dailyPrices = new uint224[](queueLength);
        Subscription storage queuedSubscription = subscriptions[
            dapiNameToCurrentSubscriptionId[dapiName]
        ];
        for (uint256 ind = 0; ind < queueLength; ind++) {
            updateParameters[ind] = updateParametersHashToValue[
                queuedSubscription.updateParametersHash
            ];
            endTimestamps[ind] = queuedSubscription.endTimestamp;
            dailyPrices[ind] = queuedSubscription.dailyPrice;
            queuedSubscription = subscriptions[
                queuedSubscription.nextSubscriptionId
            ];
        }
    }

    function subscriptionIdToUpdateParameters(
        bytes32 subscriptionId
    ) external view override returns (bytes memory updateParameters) {
        updateParameters = updateParametersHashToValue[
            subscriptions[subscriptionId].updateParametersHash
        ];
    }

    function addSubscriptionToQueue(
        bytes32 dapiName,
        bytes32 dataFeedId,
        bytes calldata updateParameters,
        uint256 duration,
        uint256 price
    ) private returns (bytes32 subscriptionId) {
        uint32 endTimestamp;
        bytes32 previousSubscriptionId;
        bytes32 nextSubscriptionId;
        (
            subscriptionId,
            endTimestamp,
            previousSubscriptionId,
            nextSubscriptionId
        ) = prospectSubscriptionPositionInQueue(
            dapiName,
            updateParameters,
            duration
        );
        bytes32 updateParametersHash = keccak256(updateParameters);
        if (updateParametersHashToValue[updateParametersHash].length == 0) {
            updateParametersHashToValue[
                updateParametersHash
            ] = updateParameters;
        }
        subscriptions[subscriptionId] = Subscription({
            updateParametersHash: updateParametersHash,
            endTimestamp: endTimestamp,
            dailyPrice: uint224((price * 1 days) / duration),
            nextSubscriptionId: nextSubscriptionId
        });
        if (previousSubscriptionId == bytes32(0)) {
            if (subscriptionId != dapiNameToCurrentSubscriptionId[dapiName]) {
                emit UpdatedCurrentSubscriptionId(dapiName, subscriptionId);
                dapiNameToCurrentSubscriptionId[dapiName] = subscriptionId;
            }
            AirseekerRegistry(airseekerRegistry).setDapiNameUpdateParameters(
                dapiName,
                updateParameters
            );
            AirseekerRegistry(airseekerRegistry).setDapiNameToBeActivated(
                dapiName
            );
            // Let's not emit SetDapiName events for no reason
            bytes32 currentDataFeedId = IApi3ServerV1(api3ServerV1)
                .dapiNameHashToDataFeedId(
                    keccak256(abi.encodePacked(dapiName))
                );
            if (currentDataFeedId != dataFeedId) {
                validateDataFeedReadiness(dataFeedId);
                IApi3ServerV1(api3ServerV1).setDapiName(dapiName, dataFeedId);
            }
        } else {
            subscriptions[previousSubscriptionId]
                .nextSubscriptionId = subscriptionId;
            bytes32 currentSubscriptionId = dapiNameToCurrentSubscriptionId[
                dapiName
            ];
            if (
                subscriptions[currentSubscriptionId].endTimestamp <=
                block.timestamp
            ) {
                _updateCurrentSubscriptionId(dapiName, currentSubscriptionId);
            }
        }
    }

    function _updateCurrentSubscriptionId(
        bytes32 dapiName,
        bytes32 currentSubscriptionId
    ) private {
        // We flush the queue all the way until we have a subscription that has
        // not ended or the queue is empty. This is safe to do, as the queue
        // length is bounded by `MAXIMUM_SUBSCRIPTION_QUEUE_LENGTH`.
        while (true) {
            currentSubscriptionId = subscriptions[currentSubscriptionId]
                .nextSubscriptionId;
            if (
                currentSubscriptionId == bytes32(0) ||
                subscriptions[currentSubscriptionId].endTimestamp >
                block.timestamp
            ) {
                break;
            }
        }
        emit UpdatedCurrentSubscriptionId(dapiName, currentSubscriptionId);
        dapiNameToCurrentSubscriptionId[dapiName] = currentSubscriptionId;
        if (currentSubscriptionId == bytes32(0)) {
            // Not reseting the dAPI name based on some discussions
            AirseekerRegistry(airseekerRegistry).setDapiNameToBeDeactivated(
                dapiName
            );
            // Leaving the update parameters set, the next subscription will be
            // cheaper
        } else {
            AirseekerRegistry(airseekerRegistry).setDapiNameUpdateParameters(
                dapiName,
                updateParametersHashToValue[
                    subscriptions[currentSubscriptionId].updateParametersHash
                ]
            );
        }
    }

    function prospectSubscriptionPositionInQueue(
        bytes32 dapiName,
        bytes calldata updateParameters,
        uint256 duration
    )
        private
        view
        returns (
            bytes32 subscriptionId,
            uint32 endTimestamp,
            bytes32 previousSubscriptionId,
            bytes32 nextSubscriptionId
        )
    {
        subscriptionId = keccak256(
            abi.encodePacked(dapiName, keccak256(updateParameters))
        );
        endTimestamp = uint32(block.timestamp + duration);
        (
            uint256 deviationThresholdInPercentage,
            int224 deviationReference,
            uint256 heartbeatInterval
        ) = abi.decode(updateParameters, (uint256, int224, uint256));
        // This function works correctly even when there are ended
        // subscriptions in the queue that need to be flushed. Its output
        // implicitly flushes them (only!) if the new subscription will be the
        // current one.
        uint256 newQueueLength = 0;
        // If the queue was empty, we immediately exit here, which
        // implies a resulting single item queue consisting of the new
        // subscription.
        // Alternatively, we may have reached the end of the queue
        // before being able to find the `nextSubscriptionId`. This
        // means `nextSubscriptionId` will be `bytes32(0)`, i.e., the
        // new subscription gets appended to the end of the queue.
        Subscription storage queuedSubscription;
        for (
            bytes32 queuedSubscriptionId = dapiNameToCurrentSubscriptionId[
                dapiName
            ];
            queuedSubscriptionId != bytes32(0);
            queuedSubscriptionId = queuedSubscription.nextSubscriptionId
        ) {
            queuedSubscription = subscriptions[queuedSubscriptionId];
            UpdateParametersComparisonResult updateParametersComparisonResult = compareUpdateParametersWithQueued(
                    deviationThresholdInPercentage,
                    deviationReference,
                    heartbeatInterval,
                    queuedSubscription.updateParametersHash
                );
            // The new subscription should be superior to every element in the
            // queue in one of the ways: It should have superior update
            // parameters, or it should have superior end timestamp. If it does
            // not, its addition to the queue does not improve it, which should
            // not be allowed.
            uint32 queuedSubscriptionEndTimestamp = queuedSubscription
                .endTimestamp;
            require(
                updateParametersComparisonResult ==
                    UpdateParametersComparisonResult.BetterThanQueued ||
                    endTimestamp > queuedSubscriptionEndTimestamp,
                "Subscription does not upgrade"
            );
            if (
                updateParametersComparisonResult ==
                UpdateParametersComparisonResult.WorseThanQueued &&
                queuedSubscriptionEndTimestamp > block.timestamp
            ) {
                // We do not check if the end timestamp is better than the
                // queued one because that is guaranteed (otherwise we would
                // have already reverted).
                // The previous subscription is one that is superior to the new
                // one. However, an ended subscription is always inferior to
                // one that has not ended. Therefore, we require the queued
                // subscription to not have ended to treat it as the previous
                // subscription. This effectively flushes the queue if the new
                // subscription turns out to be the current one.
                previousSubscriptionId = queuedSubscriptionId;
                // We keep updating `previousSubscriptionId` at each step, and
                // will stop being able to do that once we hit a subscription
                // that has equal to or worse update parameters. We can stop
                // looking for `previousSubscriptionId` after that point, but
                // doing so explicitly is unnecessarily complex, and this if
                // condition is cheap enough to evaluate redundantly.
                newQueueLength++;
            }
            if (
                updateParametersComparisonResult ==
                UpdateParametersComparisonResult.BetterThanQueued &&
                endTimestamp < queuedSubscriptionEndTimestamp
            ) {
                // In the queue, `previousSubscriptionId` comes before
                // `nextSubscriptionId`. Therefore, as soon as we find
                // `nextSubscriptionId`, we can break, as we know that we have
                // already found `previousSubscriptionId`.
                // This implicitly removes multiple sequential items from the
                // queue if they have inferior update parameters and end
                // timestamps than the new subscription, somewhat similar to
                // the implicit flushing mentioned above.
                nextSubscriptionId = queuedSubscriptionId;
                for (
                    ;
                    queuedSubscriptionId != bytes32(0);
                    queuedSubscriptionId = subscriptions[queuedSubscriptionId]
                        .nextSubscriptionId
                ) {
                    newQueueLength++;
                }
                break;
            }
        }
        require(
            newQueueLength < MAXIMUM_SUBSCRIPTION_QUEUE_LENGTH,
            "Subscription queue full"
        );
    }

    function compareUpdateParametersWithQueued(
        uint256 deviationThresholdInPercentage,
        int224 deviationReference,
        uint256 heartbeatInterval,
        bytes32 queuedUpdateParametersHash
    ) private view returns (UpdateParametersComparisonResult) {
        // If update parameters are already queued, they are guaranteed to have
        // been stored in `updateParametersHashToValue`
        (
            uint256 queuedDeviationThresholdInPercentage,
            int224 queuedDeviationReference,
            uint256 queuedHeartbeatInterval
        ) = abi.decode(
                updateParametersHashToValue[queuedUpdateParametersHash],
                (uint256, int224, uint256)
            );
        require(
            deviationReference == queuedDeviationReference,
            "Deviation references not equal"
        );
        if (
            (deviationThresholdInPercentage ==
                queuedDeviationThresholdInPercentage) &&
            (heartbeatInterval == queuedHeartbeatInterval)
        ) {
            return UpdateParametersComparisonResult.EqualToQueued;
        } else if (
            (deviationThresholdInPercentage <=
                queuedDeviationThresholdInPercentage) &&
            (heartbeatInterval <= queuedHeartbeatInterval)
        ) {
            return UpdateParametersComparisonResult.BetterThanQueued;
        } else if (
            (deviationThresholdInPercentage >=
                queuedDeviationThresholdInPercentage) &&
            (heartbeatInterval >= queuedHeartbeatInterval)
        ) {
            return UpdateParametersComparisonResult.WorseThanQueued;
        } else {
            // This is hit when one set of parameters have better deviation
            // threshold and the other has better heartbeat interval
            revert("Update parameters incomparable");
        }
    }

    function validateDataFeedReadiness(bytes32 dataFeedId) private view {
        (, uint32 timestamp) = IApi3ServerV1(api3ServerV1).dataFeeds(
            dataFeedId
        );
        require(
            block.timestamp <= timestamp + MAXIMUM_DAPI_UPDATE_AGE,
            "Data feed value stale"
        );
        require(
            AirseekerRegistry(airseekerRegistry).dataFeedIsRegistered(
                dataFeedId
            ),
            "Data feed not registered"
        );
    }

    function verifyDapiManagementMerkleProof(
        bytes32 dapiName,
        bytes32 dataFeedId,
        address sponsorWallet,
        bytes calldata dapiManagementMerkleData
    ) private view {
        require(dapiName != bytes32(0), "dAPI name zero");
        (
            bytes32 dapiManagementMerkleRoot,
            bytes32[] memory dapiManagementMerkleProof
        ) = abi.decode(dapiManagementMerkleData, (bytes32, bytes32[]));
        require(
            hashes[DAPI_MANAGEMENT_MERKLE_ROOT_HASH_TYPE].value ==
                dapiManagementMerkleRoot,
            "Invalid root"
        );
        require(
            MerkleProof.verify(
                dapiManagementMerkleProof,
                dapiManagementMerkleRoot,
                keccak256(
                    bytes.concat(
                        keccak256(
                            abi.encode(dapiName, dataFeedId, sponsorWallet)
                        )
                    )
                )
            ),
            "Invalid proof"
        );
    }

    function verifyDapiPricingMerkleProof(
        bytes32 dapiName,
        bytes calldata updateParameters,
        uint256 duration,
        uint256 price,
        bytes calldata dapiPricingMerkleData
    ) private view {
        require(
            updateParameters.length == UPDATE_PARAMETERS_LENGTH,
            "Update parameters length invalid"
        );
        require(duration != 0, "Duration zero");
        require(price != 0, "Price zero");
        (
            bytes32 dapiPricingMerkleRoot,
            bytes32[] memory dapiPricingMerkleProof
        ) = abi.decode(dapiPricingMerkleData, (bytes32, bytes32[]));
        require(
            hashes[DAPI_PRICING_MERKLE_ROOT_HASH_TYPE].value ==
                dapiPricingMerkleRoot,
            "Invalid root"
        );
        require(
            MerkleProof.verify(
                dapiPricingMerkleProof,
                dapiPricingMerkleRoot,
                keccak256(
                    bytes.concat(
                        keccak256(
                            abi.encode(
                                dapiName,
                                block.chainid,
                                updateParameters,
                                duration,
                                price
                            )
                        )
                    )
                )
            ),
            "Invalid proof"
        );
    }

    function verifySignedApiUrlMerkleProof(
        address airnode,
        string calldata signedApiUrl,
        bytes calldata signedApiUrlMerkleData
    ) private view {
        (
            bytes32 signedApiUrlMerkleRoot,
            bytes32[] memory signedApiUrlMerkleProof
        ) = abi.decode(signedApiUrlMerkleData, (bytes32, bytes32[]));
        require(
            hashes[SIGNED_API_URL_MERKLE_ROOT_HASH_TYPE].value ==
                signedApiUrlMerkleRoot,
            "Invalid root"
        );
        require(
            MerkleProof.verify(
                signedApiUrlMerkleProof,
                signedApiUrlMerkleRoot,
                keccak256(
                    bytes.concat(keccak256(abi.encode(airnode, signedApiUrl)))
                )
            ),
            "Invalid proof"
        );
    }

    function deriveBeaconId(
        address airnode,
        bytes32 templateId
    ) private pure returns (bytes32 beaconId) {
        beaconId = keccak256(abi.encodePacked(airnode, templateId));
    }
}
