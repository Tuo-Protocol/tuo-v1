# Tuo Protocol v1

This repository contains the smart contracts of Tuo Protocol v1. It uses Foundry for compilation,
testing and deployment.

## What is Tuo?

Tuo turns a single deposit into a hedged liquidity position: the deposit is converted to USDC,
deployed as Uniswap V3 concentrated liquidity and hedged with a matching short on Hyperliquid. Each
position is a transferable ERC-721 NFT, and its holder is the only account that can withdraw it.

| Contract         | Role                                                                  |
| ---------------- | --------------------------------------------------------------------- |
| `TuoVault`       | Custody, deposits and withdrawals, keeper actions, performance fee    |
| `TuoPositionNFT` | The position NFT; its owner is the withdrawal authority               |
| `TuoSwapRouter`  | Vault-only execution through allowlisted 0x and 1inch aggregators     |

## Documentation

- [Tuo Documentation](https://docs.tuo.app/)

## Audits

Cyfrin reviewed the contracts in September 2026. The fixes for the findings Tuo accepted are in the
code, and the report will be published when final in the
[Cyfrin audit reports](https://github.com/Cyfrin/cyfrin-audit-reports) repository.

## Deployments

Deployed addresses are listed per network in [`deployments/`](./deployments). The Arbitrum One
deployment is pending.

## Setup

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then restore the
dependencies pinned in `foundry.toml`:

```
forge soldeer install
forge build
```

## Test

```
forge test
```

Fork tests read `ARBITRUM_RPC_URL` (an archive node) and are skipped without it.

## Security

Report a vulnerability privately to security@tuo.app rather than opening a public issue.

## License

The contracts under `src/` are licensed under the Business Source License 1.1; vendored third-party
files keep their own licenses. `script/` and `test/` are MIT. See [LICENSE](./LICENSE).
