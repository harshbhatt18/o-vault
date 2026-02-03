# Chainlink CRE Forwarder Addresses

The KeystoneForwarder is the contract that verifies DON consensus signatures
and calls your consumer contract's `onReport()` function.

## Known Addresses

| Network          | Forwarder Address                            | Notes                    |
|------------------|----------------------------------------------|--------------------------|
| Base Sepolia     | `0x82300bd7c3958625581cc2f77bc6464dcecdf3e5` | CRE Simulation Forwarder |
| Ethereum Mainnet | Check CRE docs / CRE UI after deployment    | Production Forwarder     |
| Ethereum Sepolia | Check CRE docs / CRE UI after deployment    | Testnet Forwarder        |

**IMPORTANT:** Forwarder addresses may change. Always verify against
the latest CRE documentation at https://docs.chain.link/cre before deployment.

## Setting Up the Forwarder

1. Deploy your StreamVault contract
2. Get the correct forwarder address for your target network from CRE documentation
3. Call `vault.setChainlinkForwarder(forwarderAddress)` from the operator account
4. Deploy your CRE workflow using `cre workflow deploy`
5. The workflow will automatically use the forwarder to submit signed reports

## Sources

- https://github.com/smartcontractkit/x402-cre-price-alerts (README)
- https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/overview-ts
