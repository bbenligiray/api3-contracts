# AirseekerRegistry.sol

All API3 data feeds are served over the [Api3ServerV1](./api3serverv1.md) contract.
[Airseeker](../infrastructure/airseeker.md) is a piece of API3 data feed infrastructure that pushes API provider-signed data to Api3ServerV1 when the conditions specified on AirseekerRegistry are satisfied.
In other words, AirseekerRegistry is an on-chain configuration file for Airseeker.
This preferred for two reasons:

- The reconfiguration of data feed infrastructure through a redeployment or an API call is error-prone and should be avoided.
  On-chain reconfiguration is preferable because it can be restricted according to rules enforced by a contract (e.g., a multisig would require a specific number of signatures), which may reduce probability of errors and severity of consequences.
- The on-chain reconfiguration can be integrated to other contracts to streamline the process.
  For example, [Api3Market](./api3market.md) automatically updates AirseekerRegistry based on user payments, removing the need for any manual steps.

## How Airseeker uses AirseekerRegistry

Airseeker periodically checks if any of the active data feeds on AirseekerRegistry needs to be updated (according to the on-chain state and respective update parameters), and updates the ones that do.
`activeDataFeed()` is used for this, which returns all data that Airseeker needs about a [data feed](../contracts/api3serverv1.md#data-feeds) with a specific index.
To reduce the number of RPC calls, Airseeker batches these calls using `multicall()`.
The first of these multicalls includes an `activeDataFeedCount()` call, which tells Airseeker how many multicalls it should make to fetch data for all active data feeds (e.g., if Airseeker is making calls in batches of 10 and there are 44 active data feeds, 4 multicalls would need to be made).

In the case that the active data feeds change (in tha they become activated/deactivated) while Airseeker is making these multicalls, Airseeker may fetch the same feed in two separate batches, or miss a data feed.
This is accepted behavior, assuming that active data feeds will not change very frequently and Airseeker will run its update loop very frequently (meaning that any missed data feed will be handled on the next iteration).

Let us go over what `activeDataFeed()` returns.

```solidity
function activeDataFeed(uint256 index)
    external
    view
    returns (
        bytes32 dataFeedId,
        bytes32 dapiName,
        bytes dataFeedDetails,
        int224 dataFeedValue,
        uint32 dataFeedTimestamp,
        int224[] beaconValues,
        uint32[] beaconTimestamps,
        bytes updateParameters,
        string[] signedApiUrls
    )
```

`activeDataFeed()` returns `dataFeedId` and `dapiName`.
`dataFeedId` and `dapiName` are not needed for the update functionality, and are only provided for Airseeker to refer to in the logs.
`dataFeedDetails` is contract ABI-encoded [Airnode](../infrastructure/airnode.md) address array and template ID array belonging to the [data feed](./api3serverv1.md#data-feeds) identified by `dataFeedId`.
When a [signed API](../infrastructure/signed-api.md) is called through the URL `$SIGNED_API_URL/public/$AIRNODE_ADDRESS`, it returns an array of signed data keyed by template IDs (e.g., https://signed-api.api3.org/public/0xc52EeA00154B4fF1EbbF8Ba39FDe37F1AC3B9Fd4).
Therefore, `dataFeedDetails` is all Airseeker needs to fetch the signed data it will use to update the data feed.

`dataFeedValue` and `dataFeedTimestamp` are the current on-chain values of the data feed identified by `dataFeedId`.
These values are compared with the aggregation of the values returned by the signed APIs to determine if an update is necessary.
`beaconValues` and `beaconTimestamps` are the current values of the constituent [Beacons](./api3serverv1.md#beacon) of the data feed identified by `dataFeedId`.
Airseeker updates data feeds through a multicall of individual calls that update each underlying Beacon, followed by a call that updates the Beacon set using the Beacons.
Having the Beacon readings allows Airseeker to predict the outcome of the individual Beacon updates and omit them as necessary (e.g., if the on-chain Beacon value is fresher than what the signed API returns, which guarantees that that Beacon update will revert, Airseeker does not attempt to update that Beacon).

`updateParameters` is contract ABI-encoded update parameters in a format that Airseeker recognizes.
Currently, the only format used is

```solidity
abi.encode(deviationThresholdInPercentage, deviationReference, heartbeatInterval)
```

where

- `deviationThresholdInPercentage`(`uint256`): The minimum deviation in percentage that warrants a data feed update.
  `1e8` corresponds to `100%`.
- `deviationReference`(`int224`): The reference value against which deviation is calculated.
- `heartbeatInterval` (`uint256`): The minimum data feed update age (in seconds) that warrants a data feed update.

However, AirseekerRegistry is agnostic to this format to be future-compatible with other formats that may come up.

`signedApiUrls` are a list of signed APIs that correspond to the Airnodes used in the data feed.
To get the signed data for each Airnode address, Airseeker both uses all signed API URLs specified in its configuration file, and the respective signed API URL that may be returned here.
