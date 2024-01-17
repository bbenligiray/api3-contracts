# api3-contracts

Install the dependencies and build

```sh
pnpm install
```

Test the contracts, get test coverage and gas reports

```sh
yarn test
# Outputs to `./coverage`
yarn test:coverage
# Outputs to `.gas_report`
yarn test:gas
```

Verify that the vendor contracts are identical to the ones from their respective packages.
You will need to run this with Node.js 20, and have `wget` and `tar` on your system.

```sh
pnpm verify-vendor-contracts
```
