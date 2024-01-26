# Airnode

Airnode is a first-party oracle node designed to be operated by API providers.
Each Airnode has an EOA wallet with which it signs its data, whose address (`airnode`) is announced by the respective API provider in their DNS records.

_Airnode feed_ is an iteration on Airnode that is optimized for it to power data feeds.
It supports much larger bandwidth (i.e., number of data feeds that can be supported simultaneously) and lower latency.
