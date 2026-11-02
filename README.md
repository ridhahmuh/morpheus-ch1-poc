# Morpheus BuildersV4 — CH-1 PoC (variant B)

Foundry proof-of-concept for the Morpheus BuildersV4 finding: an ordinary
account creates a free subnet squatting another project's name, appoints
itself admin AND claimAdmin, diverts victims' staking rewards, and
permanently locks victims' principal by raising the withdrawal lock to
uint128 maximum after they stake.

- Target: BuildersV4 proxy `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9` on Base
- Fork pin: Base block 53387518, RPC `https://mainnet.base.org`
- Reporter: XCUAN

## Run

```bash
forge install foundry-rs/forge-std
forge test --fork-url https://mainnet.base.org --fork-block-number 53387518 -vv
```

All tests run against a local mainnet fork only. No mainnet transaction was
executed and no real funds were used. Attacker, victim, and innocent are
ordinary EOAs; no privileged account is pranked.

Reference numbers (1,000 MOR victim stake, 30 days): reward diverted
23.4278 MOR + principal locked 1,000 MOR = 1,023.4278 MOR (~$890 at
MOR ~$0.87, market reference 2026-11-01, not an on-chain price).
