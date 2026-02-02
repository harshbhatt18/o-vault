## StreamVault — Architecture

### The Problem

ERC-4626 assumes instant withdrawals. Real yield sources don't work that way — Kiln's staking exits take days, RWAs settle T+2, Railnet's STEAM models everything as async state transitions. Every vault in production either lies about instant availability or holds excess idle capital as a buffer (capital inefficiency).

StreamVault makes withdrawals honestly async while keeping deposits instant.

---

### Three Contracts

**StreamVault.sol** — the ERC-4626 vault with an epoch queue bolted on

**IYieldSource.sol** — one interface, four functions: `deposit`, `withdraw`, `balance`, `asset`. This is Kiln's connector pattern stripped to the bone.

**MockYieldSource.sol** — fake lending protocol. Takes USDC, accrues yield over time at a configurable rate per second. Only the vault can deposit/withdraw.

---

### The Flow

**Deposits** are completely standard ERC-4626. User calls `deposit(1000 USDC)`, gets shares, done. Assets sit idle in the vault until the operator deploys them.

**Withdrawals** are where it gets interesting. Three-step process:

Step 1 — user calls `requestWithdraw(shares)`. Shares are burned immediately. The request gets queued into the current epoch. User walks away and waits.

Step 2 — operator calls `settleEpoch()`. This snapshots the exchange rate, calculates how much USDC is owed to everyone in this epoch, pulls from the yield source if the vault doesn't have enough idle cash, marks the epoch SETTLED, and opens a new epoch.

Step 3 — user calls `claimWithdrawal(epochId)`. Gets their pro-rata share of the epoch's total USDC. Done.

---

### The Critical Accounting

This is the part that will impress in an interview — it's subtle and most people get it wrong.

**totalAssets** must equal: idle USDC in vault + yield source balance − totalClaimableAssets

Why subtract claimable? That USDC is already spoken for. It belongs to users who exited in settled epochs but haven't claimed yet. If you don't subtract it, new depositors' shares get priced against USDC that isn't really theirs. This is the same problem Kiln's Omnivault faces — you can't count exit-queue funds as vault NAV.

**The exchange rate at settlement** — when shares are burned in `requestWithdraw`, totalSupply drops but the assets are still in the vault. So at settle time, you need the "pre-burn" rate. The formula is: `assetsOwed = burnedShares × totalAssets / (totalSupply + totalPendingShares)`. You add pending shares back to the denominator to reconstruct what the rate was before the burns.

**Rounding** — always floor in favor of the vault. `mulDiv` with `Math.Rounding.Floor` everywhere. This means the vault keeps dust, which is standard ERC-4626 convention and prevents rounding exploits.

**Inflation attack protection** — override `_decimalsOffset()` to return 3. This adds virtual shares and virtual assets (1e3 of each) so the first depositor can't manipulate the exchange rate by front-running with a donation.

---

### Epoch State Machine

```
OPEN → SETTLED
 │         │
 │         └── users can claimWithdrawal()
 └── users can requestWithdraw()
     operator eventually calls settleEpoch()
```

Only one epoch is OPEN at a time. Settlement closes it and opens the next. Old settled epochs stay around forever (users can claim whenever). This is directly Railnet's STEAM concept: PENDING → SETTLED, just simplified to two states.

---

### What the Operator Does

The operator is a trusted role (in Kiln's world, this is Kiln itself or an institutional keeper). They have four powers:

**Deploy to yield** — push idle USDC from the vault into the yield source. This is how capital gets put to work.

**Withdraw from yield** — pull USDC back to idle. Needed before settlement if the vault doesn't have enough cash.

**Settle epoch** — finalize the current withdrawal batch. The key design decision is that settlement pulls from the yield source automatically if idle funds are insufficient. The operator doesn't need to manually pre-fund.

**Harvest yield** — calculate profit since last harvest, mint new shares to feeRecipient as a performance fee. Uses a high water mark so fees only apply to new profits, never the same profit twice. Fee as share dilution (not asset skimming) is the standard institutional pattern because it's transparent and auditable on-chain.

---

### Test Strategy

**Unit tests** — one test per function per scenario. The critical ones: first depositor gets correct shares, settlement calculates correct assets owed, double-claim reverts, settlement pulls from yield source when idle is insufficient, multiple users in same epoch get pro-rata correctly.

**Fuzz tests** — the killer property: `deposit(X) → requestWithdraw(allShares) → settle → claim ≈ X`. This roundtrip should preserve value within rounding tolerance. Also fuzz: rounding always favors vault (previewRedeem(previewDeposit(X)) ≤ X).

**Invariant tests** — use a handler contract that randomly deposits, requests, settles, and claims. Three invariants: (1) totalAssets == idle + yieldBalance − claimable (accounting consistency), (2) totalClaimed ≤ totalDeposited (no money from thin air), (3) if totalSupply > 0 then totalAssets > 0 (share price never zero).

---

### What to Skip (But Talk About in Interview)

**No UUPS proxy** — keep it non-upgradeable. In the interview say: "I'd add UUPSUpgradeable with `_authorizeUpgrade` restricted to admin, initializer instead of constructor, and a `__gap` for storage compatibility."

**No blocklist** — in interview say: "Kiln uses a BlockList contract checked in the ERC-20 `_update` hook for OFAC compliance. I'd override `_update` to call `blockList.isAllowed()` on both sender and receiver."

**No multi-connector** — one yield source is enough. In interview say: "Kiln's Omnivault supports multiple connectors with target weights and rebalancing. I'd add a `StrategyAllocation` struct array and a waterfall withdrawal that tries each connector in order with try/catch."

---

### How This Maps to Kiln (Your Interview Cheat Sheet)

| StreamVault | Kiln Equivalent |
|---|---|
| `requestWithdraw()` | Railnet STEAM query creation (PENDING state) |
| `settleEpoch()` | Operator settling queries (SETTLED state) |
| epoch batching | Gas-efficient batch settlement |
| burned shares tracking | Prevents double-counting during exit queue |
| `claimWithdrawal()` | User collecting after settlement |
| `IYieldSource` | Omnivault connector pattern (IConnector) |
| `totalAssets()` override | Same accounting: idle + strategies − owed |
| `_decimalsOffset()` | OZ virtual shares for inflation protection |
| performance fee as share mint | Kiln's FeeDispatcher pattern |

That's the whole architecture. Three contracts, one novel idea (epoch queue), and it touches every concept they'll ask about.