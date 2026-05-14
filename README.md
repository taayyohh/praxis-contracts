# Praxis Contracts

Smart contracts for the [Praxis network](https://ourpraxis.network) — a decentralized platform for artists to share, sell, and collect art directly.

## Contracts (Optimism L2, Chain 10)

| Contract | Address | Purpose |
|----------|---------|---------|
| ArtistRegistry | `0x4bC73F9CC7C7a84B5Cf20e1469Ad65f8b5448336` | Artist + supporter registration, follows, domains |
| Praxis | `0xA34f1d26Ff9D6fd1E36DD317987DffE2a557DDA0` | Projects, funding, credentials, dispute resolution |
| BlogRegistry | `0x839505786d0438848F5EAdBDfD11D693A3D01002` | On-chain blog posts with references |
| PraxisMedia | `0xaF995dB3955419E9E2086FD02891580F8a025481` | Media listings, purchases, collaborator splits |
| PraxisInvites | `0xbC74c3D815beC49507826A6b9e07E7f086FB744D` | Invite-only registration |
| ArtistSponsoredInvites | `0x15F5f22F130ecEF5eee15d9BA90bB73B287a4F6A` | Gas-sponsored invite codes |
| LibraryRegistry | `0x5CdDD64f20C69fC2007868476788BC3766C28A0A` | Shared knowledge base (PDFs, links, tags) |
| PraxisTicketMarket | `0x0ea62A91acE3D77Bc96d77f1B05Ff3C1C60aF74c` | Event tickets marketplace |
| PraxisTreasury | `0x5CF9E88417A7cE08028D32C44F9b63bc3d960b21` | Fee collection, ETH→USDC swap, EtherFi Cash |
| PraxisOrganization | `0x23045DF374874274497541cCF34945069447e01F` | Multi-member organizations |

All contracts are verified on [Optimism Etherscan](https://optimistic.etherscan.io).

## Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv
```

## Architecture

- **Solidity ^0.8.20** — all contracts
- **Foundry** — build, test, deploy
- **Optimism L2** — low gas costs (~$0.01-0.05 per transaction)
- **ERC-6909** — multi-token standard for media purchases (soulbound)

## License

MIT
