// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./HashRegistry.sol";
import "@api3/airnode-protocol-v1/contracts/utils/ExtendedSelfMulticall.sol";
import "./interfaces/IApi3Market.sol";
import "./vendor/@openzeppelin/contracts@4.9.5/utils/cryptography/MerkleProof.sol";
import "./AirseekerRegistry.sol";
import "@api3/airnode-protocol-v1/contracts/api3-server-v1/interfaces/IApi3ServerV1.sol";
import "@api3/airnode-protocol-v1/contracts/api3-server-v1/proxies/interfaces/IProxyFactory.sol";

contract Api3Market is HashRegistry, ExtendedSelfMulticall, IApi3Market {
    enum UpdateParametersComparisonResult {
        EqualToQueued,
        BetterThanQueued,
        WorseThanQueued
    }

    struct Subscription {
        bytes32 updateParametersHash;
        uint32 endTimestamp;
        uint224 dailyPrice;
        bytes32 nextSubscriptionId;
    }

    // We allow a subscription queue of 5. We only need as many as the number
    // of tiers we have (currently 3: 1%, 0.5%, 0.25%).
    // As a note, there may be an off-by-one error here (in that the maximum
    // queue length is actually 4 or 6).
    uint256 public constant override MAXIMUM_SUBSCRIPTION_QUEUE_LENGTH = 5;

    bytes32 public constant override DAPI_MANAGEMENT_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("dAPI management Merkle root"));

    bytes32 public constant override DAPI_PRICING_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("dAPI pricing Merkle root"));

    bytes32 public constant override SIGNED_API_URL_MERKLE_ROOT_HASH_TYPE =
        keccak256(abi.encodePacked("Signed API URL Merkle root"));

    uint256 public constant override MAXIMUM_DAPI_UPDATE_AGE = 1 days;

    address public immutable override api3ServerV1;

    address public immutable override proxyFactory;

    address public immutable override airseekerRegistry;

    // Keeping the subscriptions as a linked list
    mapping(bytes32 => Subscription) public override subscriptions;

    // Where the subscription queue starts per dAPI name
    mapping(bytes32 => bytes32) public override dapiNameToCurrentSubscriptionId;

    // There will be a very limited variety of update parameters so using their
    // hashes as a shorthand is a good optimization
    mapping(bytes32 => bytes) public override updateParametersHashToValue;

    uint256 private constant DATA_FEED_DETAILS_LENGTH_FOR_SINGLE_BEACON =
        32 + 32;

    uint256 private constant UPDATE_PARAMETERS_LENGTH = 32 + 32 + 32;

    constructor(address owner_, address proxyFactory_) HashRegistry(owner_) {
        proxyFactory = proxyFactory_;
        api3ServerV1 = IProxyFactory(proxyFactory_).api3ServerV1();
        airseekerRegistry = address(
            new AirseekerRegistry{salt: bytes32(0)}(address(this), api3ServerV1)
        );
    }

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

    // For all active dAPIs, our bot should call this whenever it won't revert
    function flushSubscriptionQueue(bytes32 dapiName) public override {
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
        _flushSubscriptionQueue(dapiName, currentSubscriptionId);
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
                _flushSubscriptionQueue(dapiName, currentSubscriptionId);
            }
        }
    }

    function _flushSubscriptionQueue(
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
