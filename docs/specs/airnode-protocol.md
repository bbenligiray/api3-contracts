# Airnode protocol

The term _Airnode protocol_ is used to refer to a range of protocols that are served by [Airnode](../infrastructure/airnode.md).
Some examples are:

- Request-response protocol: Airnode detects generic on-chain requests and responds by a fulfillment transactions
- Publish-subscribe protocol: Airnode receives generic on-chain subscriptions and fulfills them whenever their specified conditions are satisfied
- Airseeker protocol: _Airnode feed_ pre-emptively pushes signed data to a signed API, and Airseeker periodically fetches this data from the signed API to update on-chain data feeds whenever the specified conditions are satisfied
