# StreamVault — Features, Formulas & Examples

A complete reference for every mechanism in StreamVault, with the underlying math, code references, and worked numerical examples.

---

## Table of Contents

- [1. ERC-4626 Share Pricing](#1-erc-4626-share-pricing)
- [2. EMA-Smoothed NAV](#2-ema-smoothed-nav)
- [3. Epoch-Based Async Withdrawals](#3-epoch-based-async-withdrawals)
- [4. Fee System](#4-fee-system)
  - [4a. Performance Fee (HWM-Gated)](#4a-performance-fee-hwm-gated)
  - [4b. Continuous Management Fee](#4b-continuous-management-fee)
  - [4c. Withdrawal Fee](#4c-withdrawal-fee)
  - [4d. Fee Share Pricing (EMA-Based)](#4d-fee-share-pricing-ema-based)
- [5. Basel III LCR (Liquidity Coverage Ratio)](#5-basel-iii-lcr-liquidity-coverage-ratio)
- [6. Concentration Limits](#6-concentration-limits)
- [7. Drawdown Circuit Breaker](#7-drawdown-circuit-breaker)
- [8. Deposit Cap](#8-deposit-cap)
- [9. Deposit Lockup Period](#9-deposit-lockup-period)
- [10. Withdrawal Fee](#10-withdrawal-fee)
- [11. Timelocked Governance](#11-timelocked-governance)
- [12. Transfer Restrictions](#12-transfer-restrictions)
- [13. Inflation Attack Protection](#13-inflation-attack-protection)
- [14. Total Assets Accounting](#14-total-assets-accounting)
- [15. NAV Per Share](#15-nav-per-share)
- [16. CRE Risk Oracle Feedback Loop](#16-cre-risk-oracle-feedback-loop)
- [17. RBAC (Role-Based Access Control)](#17-rbac-role-based-access-control)
- [18. EIP-712 Gasless Operator Approval](#18-eip-712-gasless-operator-approval)
- [Constants Reference](#constants-reference)

---

## 1. ERC-4626 Share Pricing

**What it is:** StreamVault is an ERC-4626 tokenized vault. Users deposit USDC and receive vault shares (svUSDC). The share price is determined by the ratio of total assets to total shares.

**Source:** `StreamVault.sol:358-378` (inherits OpenZeppelin `ERC4626Upgradeable`)

### Formula

```
sharePrice = totalAssets / totalSupply
```

The inherited OZ `convertToShares` and `convertToAssets` add a virtual offset for safety (see [Inflation Attack Protection](#13-inflation-attack-protection)):

```
shares = floor(assets × (totalSupply + 10³) / (totalAssets + 1))
assets = floor(shares × (totalAssets + 1) / (totalSupply + 10³))
```

### Example

**State:** Vault holds 1,000,000 USDC. 1,000,000 shares exist.

```
Alice wants to deposit 50,000 USDC.

shares = floor(50,000 × (1,000,000 + 1,000) / (1,000,000 + 1))
       = floor(50,000 × 1,001,000 / 1,000,001)
       ≈ 50,000 shares

Alice receives ~50,000 svUSDC.
totalAssets is now 1,050,000. totalSupply is now 1,050,000.
Share price stays ~$1.00.
```

**After yield accrues** (Aave earns 20,000 USDC):

```
totalAssets = 1,070,000. totalSupply = 1,050,000.
sharePrice = 1,070,000 / 1,050,000 = $1.019 per share

Bob deposits 100,000 USDC.
shares = floor(100,000 × 1,051,000 / 1,070,001) ≈ 98,224 shares

Bob gets fewer shares because each share is now worth more than $1.
```

---

## 2. EMA-Smoothed NAV

**What it is:** Instead of using the real-time ("spot") total assets for settlement and fee pricing, the vault uses an Exponential Moving Average that converges toward spot over a configurable smoothing period. This makes donation attacks and sandwich attacks economically infeasible.

**Source:** `StreamVault.sol:663-696`

### Formula

```
elapsed = block.timestamp − lastEmaUpdateTimestamp

IF elapsed ≥ smoothingPeriod:
    EMA = spot                              (full convergence)

ELSE:
    delta = |spot − prevEMA|
    adjustment = ⌊ delta × elapsed / smoothingPeriod ⌋
    EMA = prevEMA + adjustment              (if spot > prevEMA)
    EMA = prevEMA − adjustment              (if spot < prevEMA)

FLOOR CLAMP:
    floor = ⌊ spot × 9500 / 10000 ⌋        (EMA ≥ 95% of spot)
    EMA = max(EMA, floor)

SAFETY CLAMP:
    EMA = max(EMA, 10³)                     (never below virtual offset)
```

### How It Works (Step by Step)

Think of the EMA as a heavy ball on a rubber band attached to the spot price. The ball moves toward spot, but slowly — a fraction of the distance per second.

| Time Elapsed | Fraction of Gap Closed | Description |
|---|---|---|
| 0 seconds (same block) | 0% | No change — same-block manipulation has zero impact |
| 60 seconds (1 min) | 1.67% | Barely moves |
| 600 seconds (10 min) | 16.7% | Small movement |
| 1800 seconds (30 min) | 50% | Halfway there |
| 3600 seconds (1 hour) | 100% | Snaps to spot (full convergence) |

(Assuming `smoothingPeriod = 3600` seconds)

### Example: Normal Operation

```
Time T0: Vault has 1,000,000 USDC. EMA = 1,000,000.
         Aave earns 5,000 USDC in yield.
         spot = 1,005,000.

Time T0 + 600s (10 min later, someone deposits):
    delta = 1,005,000 − 1,000,000 = 5,000
    adjustment = ⌊ 5,000 × 600 / 3600 ⌋ = 833
    EMA = 1,000,000 + 833 = 1,000,833

Time T0 + 1800s (30 min later, settlement):
    delta = 1,005,000 − 1,000,833 = 4,167
    elapsed since last update = 1200s
    adjustment = ⌊ 4,167 × 1200 / 3600 ⌋ = 1,389
    EMA = 1,000,833 + 1,389 = 1,002,222

Time T0 + 3600s (1 hour later):
    EMA snaps to 1,005,000 (full period elapsed)
```

### Example: Donation Attack (Blocked)

```
State: 1,000,000 USDC in vault. 1,000,000 shares. EMA = 1,000,000.
smoothingPeriod = 3600 seconds.

Attacker's Plan:
  1. Deposit 100,000 shares (costs 100,000 USDC)
  2. Send 500,000 USDC directly to the vault contract (donation)
  3. Trigger epoch settlement
  4. Claim at inflated price → profit

Block N: Attacker donates 500,000 USDC.
  spot = 1,500,000 (idle jumped from 1,000,000 to 1,500,000)
  elapsed = 12 seconds since last EMA update

  delta = 1,500,000 − 1,000,000 = 500,000
  adjustment = ⌊ 500,000 × 12 / 3600 ⌋ = 1,666
  EMA = 1,000,000 + 1,666 = 1,001,666

Block N: Settlement uses EMA, not spot.
  Attacker's 100,000 shares value:
    assetsOwed = ⌊ 100,000 × 1,001,666 / 1,100,000 ⌋ = 91,060 USDC

  Without EMA (naive vault):
    assetsOwed = ⌊ 100,000 × 1,500,000 / 1,100,000 ⌋ = 136,363 USDC

  Attack result:
    With EMA:    Received 91,060.  Donated 500,000. NET LOSS: -508,940 USDC
    Without EMA: Received 136,363. Donated 500,000. Can recover 500,000. NET GAIN: 36,363 USDC

  The EMA makes the attack catastrophically unprofitable.
```

### Example: The 95% Floor (Anti-Sandbagging)

```
State: EMA = 1,000,000. spot suddenly drops to 800,000 (yield source loss).

Without floor:
  EMA stays at 1,000,000 for a long time.
  Attacker could deposit at the high EMA-priced shares, then claim
  when EMA catches down — buying cheap, selling high.

With floor:
  floor = ⌊ 800,000 × 9500 / 10000 ⌋ = 760,000
  EMA = max(1,000,000, 760,000) → stays at 1,000,000? No —

  Actually the EMA moves down via the formula:
  If elapsed = 600s, delta = 200,000
  adjustment = ⌊ 200,000 × 600 / 3600 ⌋ = 33,333
  EMA = 1,000,000 − 33,333 = 966,667
  floor = 760,000
  966,667 > 760,000 → floor not hit yet, EMA = 966,667

  But if EMA dropped further (e.g., to 750,000 from prior updates):
  floor = 760,000
  750,000 < 760,000 → EMA clamped to 760,000

  This ensures EMA never lags more than 5% behind spot,
  preventing the reverse attack.
```

### Where EMA Is Used

| Operation | Uses EMA? | Why |
|---|---|---|
| `settleEpoch()` — calculate withdrawal payouts | Yes (`emaTotalAssets`) | Prevents donation/sandwich attacks on withdrawals |
| `harvestYield()` — mint performance fee shares | Yes (via `FeeLib.convertToSharesAtEma`) | Prevents operator from minting cheap fee shares during spot inflation |
| `_accrueManagementFee()` — mint management fee shares | Yes (via `FeeLib.convertToSharesAtEma`) | Same reason as above |
| `navPerShare()` — external reporting | Yes | Smoothed NAV for integrations |
| `deposit()` — mint shares to depositor | No (uses spot via OZ `convertToShares`) | Depositors get fair spot pricing |
| `convertToShares()` / `convertToAssets()` | No (uses spot) | Standard ERC-4626 view functions |

---

## 3. Epoch-Based Async Withdrawals

**What it is:** Withdrawals are processed through a 3-step queue. Shares are burned immediately on request, but USDC is only paid out after the epoch is settled. This prevents sandwich attacks on redemptions and handles illiquid yield sources (staking exits, RWA settlements).

**Source:** `StreamVault.sol:478-537, 1295-1345`

### Formulas

**Step 1 — Request** (`requestWithdraw`):
```
epoch.totalSharesBurned += shares
totalPendingShares += shares
withdrawRequests[epochId][user].shares = shares
```

**Step 2 — Settlement** (`settleEpoch`):
```
PRECONDITION: block.timestamp − epochOpenedAt ≥ 300 seconds

effectiveSupply = totalSupply() + totalPendingShares
assetsOwed = ⌊ totalSharesBurned × emaTotalAssets / effectiveSupply ⌋

IF assetsOwed > availableIdle:
    Pull from yield sources in order (waterfall) until funded

totalPendingShares −= totalSharesBurned
totalClaimableAssets += assetsOwed
```

**Step 3 — Claim** (`claimWithdrawal`):
```
grossPayout = ⌊ userShares × totalAssetsOwed / totalSharesBurned ⌋
fee = ⌊ grossPayout × withdrawalFeeBps / 10000 ⌋
netPayout = grossPayout − fee
```

### Example

```
State: 1,000,000 USDC total. 1,000,000 shares. EMA = 1,000,000.
       200,000 idle, 500,000 in Aave, 300,000 in Morpho.

Step 1 — Requests come in during Epoch #5:
  Alice requests 50,000 shares
  Bob requests 30,000 shares

  epoch.totalSharesBurned = 80,000
  totalPendingShares = 80,000

Step 2 — Operator calls settleEpoch() after 5+ minutes:
  effectiveSupply = 920,000 (totalSupply, shares already burned)
                  + 80,000  (totalPendingShares)
                  = 1,000,000

  assetsOwed = ⌊ 80,000 × 1,000,000 / 1,000,000 ⌋ = 80,000 USDC

  available idle = 200,000 − 0 (no prior claimables) = 200,000
  80,000 < 200,000 → no need to pull from yield sources ✓

  epoch.totalAssetsOwed = 80,000
  totalClaimableAssets += 80,000

Step 3 — Claims (assuming 0.5% withdrawal fee, 50 bps):
  Alice: grossPayout = ⌊ 50,000 × 80,000 / 80,000 ⌋ = 50,000
         fee = ⌊ 50,000 × 50 / 10000 ⌋ = 250
         Alice receives: 49,750 USDC
         Fee recipient receives: 250 USDC

  Bob:   grossPayout = ⌊ 30,000 × 80,000 / 80,000 ⌋ = 30,000
         fee = ⌊ 30,000 × 50 / 10000 ⌋ = 150
         Bob receives: 29,850 USDC
         Fee recipient receives: 150 USDC
```

### Waterfall Pull Example

```
Same state, but now assetsOwed = 250,000 USDC.
Available idle = 200,000.
Shortfall = 250,000 − 200,000 = 50,000

Waterfall:
  Source 0 (Aave):  balance = 500,000. Pull min(50,000, 500,000) = 50,000
  Remaining: 0 ✓

If shortfall was 600,000:
  Source 0 (Aave):  Pull min(600,000, 500,000) = 500,000. Remaining: 100,000
  Source 1 (Morpho): Pull min(100,000, 300,000) = 100,000. Remaining: 0 ✓

If shortfall exceeded all sources: REVERT InsufficientLiquidity
```

---

## 4. Fee System

### 4a. Performance Fee (HWM-Gated)

**What it is:** A percentage of profits charged only when a yield source exceeds its previous peak balance (high water mark). Prevents double-charging on loss recovery.

**Source:** `StreamVault.sol:590-622`, `FeeLib.sol:19-22`

#### Formula

```
perSourceProfit[i] = max(0, currentBalance[i] − HWM[i])
totalProfit = Σ perSourceProfit[i]
feeAssets = ⌊ totalProfit × performanceFeeBps / 10000 ⌋
```

#### Example

```
performanceFeeBps = 1000 (10%)

Harvest #1:
  Aave balance: 520,000 (HWM was 500,000)
  Morpho balance: 290,000 (HWM was 300,000)  ← BELOW HWM, no fee

  Aave profit  = 520,000 − 500,000 = 20,000
  Morpho profit = max(0, 290,000 − 300,000) = 0  ← loss, no fee
  totalProfit = 20,000

  feeAssets = ⌊ 20,000 × 1000 / 10000 ⌋ = 2,000 USDC worth of fee shares

  New HWMs: Aave = 520,000, Morpho = 300,000 (unchanged — no new peak)

Harvest #2 (later):
  Aave balance: 525,000 (HWM = 520,000)
  Morpho balance: 310,000 (HWM = 300,000)

  Aave profit  = 525,000 − 520,000 = 5,000
  Morpho profit = 310,000 − 300,000 = 10,000
  totalProfit = 15,000

  feeAssets = ⌊ 15,000 × 1000 / 10000 ⌋ = 1,500 USDC worth of fee shares

  Note: Morpho recovered from 290K → 310K, but fee is only on the
  10K above the old HWM (300K), not on the 20K recovery from 290K to 310K.
  This is fair — you don't pay fees on money you already lost.
```

### 4b. Continuous Management Fee

**What it is:** An annual management fee charged continuously via time-proportional share dilution on every vault interaction. There is no discrete fee event that could be front-run.

**Source:** `StreamVault.sol:630-656`, `FeeLib.sol:30-37`

#### Formula

```
elapsed = block.timestamp − lastFeeAccrualTimestamp
feeAssets = ⌊ netAssets × managementFeeBps × elapsed / (SECONDS_PER_YEAR × 10000) ⌋

Where SECONDS_PER_YEAR = 31,557,600 (365.25 days)
```

Rearranged for intuition:
```
feeAssets = netAssets × (feeBps / 10000) × (elapsed / SECONDS_PER_YEAR)
          = netAssets × annualRate × fractionOfYear
```

#### Example

```
managementFeeBps = 200 (2% annual)
netAssets = 10,000,000 USDC
elapsed = 86,400 seconds (1 day)

feeAssets = ⌊ 10,000,000 × 200 × 86,400 / (31,557,600 × 10,000) ⌋
          = ⌊ 172,800,000,000,000 / 315,576,000,000 ⌋
          = ⌊ 547.67 ⌋
          = 547 USDC

Per day, the vault charges ~547 USDC on a 10M vault at 2% annual.
Annualized: 547 × 365.25 ≈ 199,862 USDC ≈ 2% of 10M ✓

Key property: This fee accrues on EVERY interaction (deposit, withdraw,
settle, harvest). There is no single "harvest" event to front-run.
```

### 4c. Withdrawal Fee

**What it is:** An exit fee (0-1%) deducted from withdrawal payouts and sent to the fee recipient as USDC.

**Source:** `FeeLib.sol:43-46`

#### Formula

```
fee = ⌊ payout × withdrawalFeeBps / 10000 ⌋
netPayout = payout − fee
```

#### Example

```
withdrawalFeeBps = 50 (0.5%)
User claims 100,000 USDC from a settled epoch.

fee = ⌊ 100,000 × 50 / 10000 ⌋ = 500 USDC
netPayout = 100,000 − 500 = 99,500 USDC

User receives:    99,500 USDC
Fee recipient:    500 USDC
```

### 4d. Fee Share Pricing (EMA-Based)

**What it is:** When the vault mints fee shares (for performance or management fees), it prices them using the EMA — not spot totalAssets. This prevents an inflated spot from allowing the operator to mint more shares than deserved.

**Source:** `FeeLib.sol:55-63`

#### Formula

```
feeShares = ⌊ feeAssets × (totalSupply + 10³) / (emaTotalAssets + 1) ⌋
```

#### Example

```
feeAssets = 2,000 USDC (performance fee from harvest)
totalSupply = 1,000,000 shares
emaTotalAssets = 1,050,000

feeShares = ⌊ 2,000 × (1,000,000 + 1,000) / (1,050,000 + 1) ⌋
          = ⌊ 2,000 × 1,001,000 / 1,050,001 ⌋
          = ⌊ 1,906.66 ⌋
          = 1,906 shares minted to fee recipient

Why EMA matters:
  If spot was manipulated to 2,000,000 but EMA is 1,050,000:
    With EMA:  1,906 shares (correct)
    With spot: ⌊ 2,000 × 1,001,000 / 2,000,001 ⌋ = 1,001 shares

  Without EMA, the operator mints fewer shares (they appear cheaper),
  which means LESS dilution for themselves — they'd be under-charging.

  Actually, the real risk is the opposite: if an attacker inflates spot
  and the fee is charged, fewer shares would be minted for the same fee,
  meaning the fee recipient gets less value. EMA protects both sides.
```

---

## 5. Basel III LCR (Liquidity Coverage Ratio)

**What it is:** A risk metric borrowed from Basel III banking regulation. It measures whether the vault holds enough liquid assets to cover stressed outflows (a depositor panic scenario). The vault enforces a minimum LCR on every capital deployment.

**Source:** `StreamVault.sol:874-904`, `RiskModel.sol:41-56`

### Background: Basel III in 60 Seconds

After the 2008 financial crisis, banks were failing because they held illiquid assets (mortgages) but owed liquid liabilities (deposits). They were **solvent on paper but couldn't pay withdrawals**. Basel III introduced:

```
LCR = High-Quality Liquid Assets (HQLA) / Net Cash Outflows (30-day stress) ≥ 100%
```

The bank must hold $1 of liquid assets for every $1 it might need to pay out in a 30-day panic.

### StreamVault's On-Chain LCR

#### Formula

```
FOR each yield source i:
    HQLA[i] = balance[i] × (10000 − haircutBps[i]) / 10000
    stressedOutflow[i] = balance[i] × stressOutflowBps[i] / 10000

totalHQLA = Σ HQLA[i] + availableIdle
totalStressedOutflows = Σ stressedOutflow[i] + pendingWithdrawals

LCR = totalHQLA × 10000 / totalStressedOutflows    (result in bps)
```

Where:
- **Haircut** = how much value you'd lose liquidating under stress (assigned by CRE oracle)
- **Stress outflow** = how much of this position might be demanded back in a panic
- **Available idle** = USDC sitting in the vault minus already-claimed amounts (no haircut — cash is cash)
- **Pending withdrawals** = shares burned in the current epoch, waiting to be settled

#### Mapping to Basel III

| Basel III Concept | StreamVault Equivalent |
|---|---|
| **Cash in vault** (Level 1 HQLA, no haircut) | `availableIdle` — USDC in the contract |
| **Government bonds** (Level 1, no haircut) | N/A (could add T-bill yield source) |
| **Corporate bonds** (Level 2A, 15% haircut) | Aave balance with CRE-assigned haircut |
| **Equities / lower-grade** (Level 2B, 25-50% haircut) | Riskier yield sources with higher haircuts |
| **Retail deposit run-off** (5-10%) | `stressOutflowBps` per source (CRE-assigned) |
| **Wholesale funding run-off** (25-100%) | Higher stress outflows for volatile sources |
| **Committed credit lines** | `pendingWithdrawals` (shares already burned) |
| **Minimum 100% LCR** | `lcrFloorBps` (configurable, e.g., 12000 = 120%) |

### Example: Computing LCR

```
Vault State:
  200,000 USDC idle
  500,000 USDC in Aave    (haircut: 1500 bps = 15%, stress outflow: 3000 bps = 30%)
  300,000 USDC in Morpho   (haircut: 2000 bps = 20%, stress outflow: 3000 bps = 30%)
  50,000 shares pending withdrawal
  totalClaimableAssets = 0

Step 1 — HQLA (what we can liquidate under stress):
  Aave HQLA   = 500,000 × (10000 − 1500) / 10000 = 500,000 × 85% = 425,000
  Morpho HQLA = 300,000 × (10000 − 2000) / 10000 = 300,000 × 80% = 240,000
  Idle HQLA   = 200,000 (no haircut — cash is cash)

  Total HQLA = 425,000 + 240,000 + 200,000 = 865,000

Step 2 — Stressed Outflows (what we'd need to pay in a panic):
  Aave outflow   = 500,000 × 3000 / 10000 = 150,000
  Morpho outflow = 300,000 × 3000 / 10000 = 90,000
  Pending withdrawals = 50,000

  Total Outflows = 150,000 + 90,000 + 50,000 = 290,000

Step 3 — LCR:
  LCR = 865,000 × 10000 / 290,000 = 29,827 bps = 298.27%

  Floor is 12,000 bps (120%).
  29,827 > 12,000 → HEALTHY ✓
```

### Example: LCR Blocking a Deployment

```
Same state. Operator wants to deploy 180,000 USDC to Aave.

After deployment:
  Idle: 200,000 − 180,000 = 20,000
  Aave: 500,000 + 180,000 = 680,000
  Morpho: 300,000 (unchanged)

New HQLA:
  Aave   = 680,000 × 85% = 578,000
  Morpho = 300,000 × 80% = 240,000
  Idle   = 20,000
  Total  = 838,000

New Outflows:
  Aave   = 680,000 × 30% = 204,000
  Morpho = 300,000 × 30% = 90,000
  Pending = 50,000
  Total  = 344,000

New LCR = 838,000 × 10000 / 344,000 = 24,360 bps = 243.6%
24,360 > 12,000 → PASSES ✓
```

Now imagine a crisis — CRE updates Aave haircut to 6000 bps (60%) because utilization spiked to 98%:

```
Crisis LCR:
  Aave HQLA  = 680,000 × (10000 − 6000) / 10000 = 680,000 × 40% = 272,000
  Morpho HQLA = 240,000
  Idle = 20,000
  Total HQLA = 532,000

  Outflows unchanged = 344,000
  LCR = 532,000 × 10000 / 344,000 = 15,465 bps = 154.6%

  Still above 120% floor. But if operator tries to deploy MORE:

  Deploy another 10,000 to Aave:
  Idle: 10,000. Aave: 690,000.

  Aave HQLA = 690,000 × 40% = 276,000
  Total HQLA = 276,000 + 240,000 + 10,000 = 526,000

  Aave outflow = 690,000 × 30% = 207,000
  Total outflows = 207,000 + 90,000 + 50,000 = 347,000

  LCR = 526,000 × 10000 / 347,000 = 15,158 bps = 151.6%

  Still passes. But add more withdrawal requests (200,000 shares):
  Total outflows = 347,000 + 200,000 = 547,000
  LCR = 526,000 × 10000 / 547,000 = 9,616 bps = 96.2%

  9,616 < 12,000 → REVERT LCRBreached(9616, 12000) 🛑
  Deployment blocked. Vault must maintain liquidity.
```

### CRE Escalation Ladder

The Chainlink CRE workflow runs every 5 minutes and triggers actions based on the simulated stressed LCR:

| LCR Range | Status | CRE Action |
|---|---|---|
| > 15,000 bps (150%) | GREEN | Update risk parameters only |
| 12,000–15,000 bps (120–150%) | YELLOW | Update params + tighten concentration limits |
| 10,000–12,000 bps (100–120%) | ORANGE | **Defensive rebalance** — pull capital from riskiest source to idle |
| < 10,000 bps (100%) | RED | **Emergency pause** — halt deposits |

---

## 6. Concentration Limits

**What it is:** No single yield source can hold more than a CRE-specified percentage of total vault assets. Prevents over-concentration in one protocol.

**Source:** `StreamVault.sol:561-568`, `RiskModel.sol:63-71`

### Formula

```
concentrationBps = sourceBalance × 10000 / totalAssets
breached = concentrationBps > maxConcentrationBps
```

### Example

```
totalAssets = 1,000,000
Aave balance after deployment = 650,000
maxConcentrationBps = 6000 (60%)

concentrationBps = 650,000 × 10000 / 1,000,000 = 6,500 bps = 65%
6,500 > 6,000 → REVERT ConcentrationBreached(aaveAddress) 🛑

Operator must deploy no more than 600,000 to Aave (60% of 1M).
```

---

## 7. Drawdown Circuit Breaker

**What it is:** If the vault's NAV per share drops more than a configured percentage from its all-time high, the vault auto-pauses. This protects depositors from cascading losses.

**Source:** `StreamVault.sol:710-731`

### Formula

```
IF currentNav > navHighWaterMark:
    navHighWaterMark = currentNav    (update peak)

ELSE:
    drawdownBps = (HWM − currentNav) × 10000 / HWM

    IF drawdownBps ≥ maxDrawdownBps AND !paused:
        auto-pause vault
```

### Example

```
maxDrawdownBps = 1000 (10%, the default)
navHighWaterMark = 1.05e18 ($1.05 per share)

Scenario A — Yield source loses money:
  currentNav = 0.98e18 ($0.98 per share)
  drawdownBps = (1.05e18 − 0.98e18) × 10000 / 1.05e18
              = 0.07e18 × 10000 / 1.05e18
              = 666 bps = 6.66%

  666 < 1000 → no action (6.66% < 10% threshold)

Scenario B — Major loss:
  currentNav = 0.93e18 ($0.93 per share)
  drawdownBps = (1.05e18 − 0.93e18) × 10000 / 1.05e18
              = 0.12e18 × 10000 / 1.05e18
              = 1,142 bps = 11.42%

  1,142 ≥ 1,000 → AUTO-PAUSE 🛑

  Vault pauses automatically. No deposits or withdrawal requests accepted.
  Existing settled epoch claims still work (claims bypass pause).
  Operator must investigate, potentially rebalance, then unpause.
```

---

## 8. Deposit Cap

**What it is:** Configurable maximum total assets the vault can hold. Prevents over-concentration of TVL and manages strategy capacity. Zero means unlimited.

**Source:** `StreamVault.sol:418-433`

### Formula

```
maxDeposit = 0                              if paused
           = type(uint256).max              if depositCap == 0 (unlimited)
           = 0                              if totalAssets ≥ depositCap
           = depositCap − totalAssets       otherwise

maxMint = convertToShares(maxDeposit)
```

### Example

```
depositCap = 10,000,000 USDC (10M)
totalAssets = 8,500,000 USDC

maxDeposit = 10,000,000 − 8,500,000 = 1,500,000 USDC

Alice tries to deposit 2,000,000:
  2,000,000 > 1,500,000 → REVERT (ERC-4626 enforces maxDeposit)

Alice deposits 1,500,000:
  totalAssets = 10,000,000 → cap reached
  maxDeposit = 0 → no more deposits accepted
```

---

## 9. Deposit Lockup Period

**What it is:** After depositing, shares cannot be withdrawn for a configurable period (0-7 days). Prevents flash-deposit-before-harvest gaming where someone deposits right before a fee harvest to get shares at pre-fee prices.

**Source:** `StreamVault.sol:480-482`

### Formula

```
lockupViolated = (lockupPeriod > 0) AND (block.timestamp < depositTimestamp[user] + lockupPeriod)
```

### Example

```
lockupPeriod = 1 day (86,400 seconds)

T0: Alice deposits 100,000 USDC. depositTimestamp[alice] = T0.

T0 + 3600 (1 hour later):
  Alice calls requestWithdraw(100,000 shares).
  block.timestamp = T0 + 3600
  T0 + 3600 < T0 + 86,400 → REVERT LockupPeriodActive() 🛑

T0 + 86,401 (1 day + 1 second later):
  Alice calls requestWithdraw(100,000 shares).
  T0 + 86,401 ≥ T0 + 86,400 → PASSES ✓
```

---

## 10. Withdrawal Fee

See [4c. Withdrawal Fee](#4c-withdrawal-fee) for the formula and example. Summary:

```
fee = ⌊ payout × withdrawalFeeBps / 10000 ⌋     (max 100 bps = 1%)
netPayout = payout − fee
fee sent to feeRecipient as USDC
```

---

## 11. Timelocked Governance

**What it is:** Critical operator actions (fee changes, yield source management, upgrades, timelock delay itself) require a schedule → wait → execute pattern when a timelock is active. Emergency actions (pause/unpause) bypass the timelock.

**Source:** `StreamVault.sol:1049-1098`

### Formula

```
readyAt = block.timestamp + timelockDelay

SCHEDULE: Store (actionId, dataHash, readyAt)
EXECUTE:  Require block.timestamp ≥ readyAt AND dataHash matches
CANCEL:   Delete pending action
```

### Example

```
timelockDelay = 24 hours (86,400 seconds)

Step 1 — Operator schedules a management fee change:
  action = TIMELOCK_SET_MGMT_FEE
  data = abi.encode(300)  // change to 3% annual
  readyAt = block.timestamp + 86,400

  Depositors see the pending action on-chain and have 24 hours to exit
  if they disagree.

Step 2 — 24 hours pass. Operator executes:
  block.timestamp ≥ readyAt → PASSES ✓
  Management fee updated to 300 bps.

If operator tries to execute early (12 hours in):
  block.timestamp < readyAt → REVERT TimelockNotReady() 🛑

Self-timelocked: setTimelockDelay() itself requires the timelock
when active. This prevents the operator from setting delay to 0
to bypass all other timelocks.
```

### Timelocked vs Emergency Actions

| Action | Timelocked? | Why |
|---|---|---|
| `setManagementFee()` | Yes | Fee change affects all depositors |
| `addYieldSource()` | Yes | New source affects risk profile |
| `removeYieldSource()` | Yes | Removing source affects liquidity |
| `setWithdrawalFee()` | Yes | Exit fee change affects withdrawers |
| `upgradeToAndCall()` | Yes | Implementation change is critical |
| `setTimelockDelay()` | Yes | Prevents self-bypass |
| `pause()` | No | Emergency — must be instant |
| `unpause()` | No | Recovery — must be instant |

---

## 12. Transfer Restrictions

**What it is:** Optional whitelist mode for ERC-20 share transfers. When enabled, only whitelisted addresses can receive shares. Mints (deposits) and burns (withdrawals) are always unrestricted.

**Source:** `StreamVault.sol` (transfer hook override)

### Logic

```
IF transfersRestricted AND to ≠ address(0) AND from ≠ address(0):
    REQUIRE transferWhitelist[to] == true
    Otherwise REVERT TransferRestricted()
```

### Example

```
vault.setTransfersRestricted(true);
vault.setTransferWhitelist(treasuryAddress, true);

Alice deposits 100,000 USDC → receives shares.       ✓ (mint, unrestricted)
Alice transfers shares to treasuryAddress.             ✓ (whitelisted)
Alice transfers shares to randomAddress.               🛑 TransferRestricted()
Alice calls requestWithdraw(shares).                   ✓ (burn, unrestricted)
```

---

## 13. Inflation Attack Protection

**What it is:** The vault uses a `_decimalsOffset() = 3` which adds 1000 virtual shares and 1 virtual asset to the ERC-4626 conversion math. This makes first-depositor inflation attacks unprofitable.

**Source:** `StreamVault.sol:376-378`

### Formula

OZ ERC-4626 with offset:
```
shares = ⌊ assets × (totalSupply + 10³) / (totalAssets + 1) ⌋
assets = ⌊ shares × (totalAssets + 1) / (totalSupply + 10³) ⌋
```

### Why It Matters

Without offset, an attacker can:
1. Deposit 1 wei → get 1 share
2. Donate 1,000,000 USDC to the vault
3. Now 1 share = 1,000,000 USDC
4. Next depositor deposits 999,999 USDC → gets 0 shares (rounds to 0)
5. Attacker redeems 1 share → gets 1,999,999 USDC

With offset (10³ virtual shares):
1. Attacker deposits 1 wei → gets ~1000 shares (virtual offset)
2. Donates 1,000,000 → total = 1,000,000. 1001 shares exist.
3. Next depositor deposits 999,999 → gets ~999 shares (not 0)
4. Attack is unprofitable — attacker donated 1M but only controls 1001/2000 shares

---

## 14. Total Assets Accounting

**What it is:** The vault's total value is the sum of idle balance plus all deployed balances, minus assets already owed to settled epochs.

**Source:** `StreamVault.sol:358-373`

### Formula

```
totalAssets = idle + Σ yieldSources[i].balance() − totalClaimableAssets

Where:
  idle = IERC20(asset()).balanceOf(address(vault))
  totalClaimableAssets = sum of all assetsOwed from settled but unclaimed epochs
```

### Example

```
USDC in vault contract:   200,000
Aave aToken balance:      500,026  (500K + yield accrued)
Morpho supply shares:     300,000
totalClaimableAssets:      80,000   (from settled epoch, not yet claimed)

totalAssets = 200,000 + 500,026 + 300,000 − 80,000 = 920,026 USDC

The 80,000 is excluded because it's already spoken for — it belongs
to users who haven't claimed their settled withdrawals yet.
```

---

## 15. NAV Per Share

**What it is:** The smoothed (EMA-based) value of each vault share, reported in 18-decimal fixed point.

**Source:** `StreamVault.sol:700-705`

### Formula

```
navPerShare = 1e18                                       if totalSupply == 0
            = ⌊ emaTotalAssets × 1e18 / totalSupply ⌋   otherwise
```

### Example

```
emaTotalAssets = 1,050,000 USDC (6 decimals)
totalSupply = 1,000,000 shares

navPerShare = ⌊ 1,050,000 × 1e18 / 1,000,000 ⌋
            = 1.05e18
            = $1.05 per share (in 18-decimal precision)

This uses EMA, not spot, so it reflects the smoothed value.
A donation that inflates spot to 2,000,000 while EMA is 1,050,000
would still report navPerShare as $1.05.
```

---

## 16. CRE Risk Oracle Feedback Loop

**What it is:** A Chainlink Compute Runtime Environment (CRE) workflow runs every 5 minutes on the Chainlink DON (Decentralized Oracle Network). It reads real protocol health data, computes risk scores, and submits signed reports that update the vault's risk parameters.

**Source:** `cre/risk-monitor-workflow/` (TypeScript), `StreamVault.sol` (`onReport()`)

### Workflow

```
Every 5 minutes:
┌─────────────────────────────────────────────────────────────┐
│ 1. MONITOR: Read on-chain state via EVMClient               │
│    • Aave utilization (getReserveData)                       │
│    • Aave available liquidity                                │
│    • Morpho utilization (market state)                       │
│    • Morpho available liquidity                              │
│    • Vault: idle, deployed, pending withdrawals, current LCR │
│                                                              │
│ 2. COMPUTE: 3-layer risk model                               │
│    Layer 1: Per-source risk scores (0-10000)                 │
│      score = w1×utilization + w2×liquidityRatio              │
│            + w3×oracleDeviation + w4×concentration            │
│    Layer 2: Stressed LCR simulation                          │
│      Simulate 30% redemption shock with haircuts             │
│    Layer 3: Action decision engine                           │
│      Based on stressed LCR thresholds                        │
│                                                              │
│ 3. REPORT: DON consensus + ECDSA signing                     │
│    BFT agreement among DON nodes                             │
│    Signed report delivered via KeystoneForwarder              │
│                                                              │
│ 4. ENFORCE: vault.onReport() stores new parameters           │
│    Updated haircuts, stress outflows, concentration limits    │
│    Next deployToYield() uses the new params                  │
└─────────────────────────────────────────────────────────────┘
```

### Risk Parameter Struct

```solidity
struct SourceRiskParams {
    uint16 liquidityHaircutBps;     // 0-9500: haircut in LCR calculation
    uint16 stressOutflowBps;        // 0-10000: expected stress outflow
    uint16 maxConcentrationBps;     // 0-10000: max % of TVL deployable
    uint64 lastUpdated;             // timestamp of last CRE update
    uint8  riskTier;                // 0=GREEN, 1=YELLOW, 2=ORANGE, 3=RED
}
```

### Layer 1: Per-Source Risk Score (0-10,000)

CRE reads 4 on-chain metrics per source and computes a weighted composite score.

**Source:** `cre/risk-monitor-workflow/risk-model.ts` — `computeSourceRiskScore()`

```
score = (utilizationRisk × 3500 + liquidityRisk × 3000 + oracleRisk × 2000 + concentrationRisk × 1500) / 10000
```

**Sub-score formulas:**

**a) Utilization Risk (weight: 35%)** — How full is the lending pool?

```
utilization < 80%    →  utilizationRisk = utilization × 500 / 8000   (gentle linear slope)
80% – 90%            →  utilizationRisk = 3,000
90% – 95%            →  utilizationRisk = 7,000
> 95%                →  utilizationRisk = 10,000  (critical)
```

**b) Liquidity Risk (weight: 30%)** — How large is the vault's position vs available pool liquidity?

```
liquidityRisk = min(vaultExposure × 10000 / availableLiquidity, 10000)

If availableLiquidity = 0 and vaultExposure > 0 → liquidityRisk = 10,000
```

**c) Oracle Risk (weight: 20%)** — How much has the price feed deviated?

```
oracleRisk = min(oracleDeviationBps × 20, 10000)

Example: 100 bps (1%) deviation → 100 × 20 = 2,000
         500 bps (5%) deviation → 500 × 20 = 10,000 (max)
```

**d) Concentration Risk (weight: 15%)** — What % of vault TVL sits in this one source?

```
concentrationRisk = vaultExposure × 10000 / totalVaultAssets
```

### Layer 2: Risk Score → Haircut, Stress Outflow, Concentration Limit

The composite risk score maps to three output parameters through lookup tables.

**Risk Score → Liquidity Haircut** (`riskScoreToHaircut`)

| Risk Score | Haircut | Effect on LCR |
|-----------|---------|---------------|
| 0 – 1,999 | 500 bps (5%) | Count 95% of balance as liquid |
| 2,000 – 3,999 | 1,500 bps (15%) | Count 85% of balance |
| 4,000 – 5,999 | 3,000 bps (30%) | Count 70% of balance |
| 6,000 – 7,999 | 5,000 bps (50%) | Count only 50% |
| 8,000 – 10,000 | 7,500 bps (75%) | Count only 25% |

**Risk Score → Stress Outflow Rate** (`riskScoreToStressOutflow`)

| Risk Score | Stress Outflow | Meaning |
|-----------|---------------|---------|
| 0 – 1,999 | 1,000 bps (10%) | Expect 10% redemptions under stress |
| 2,000 – 3,999 | 2,000 bps (20%) | Expect 20% redemptions |
| 4,000 – 5,999 | 3,000 bps (30%) | Expect 30% redemptions |
| 6,000 – 7,999 | 5,000 bps (50%) | Expect 50% redemptions |
| 8,000 – 10,000 | 7,000 bps (70%) | Expect 70% redemptions |

**Risk Score → Max Concentration Limit**

| Risk Score | Max Concentration | Effect |
|-----------|------------------|--------|
| 0 – 4,000 | 6,000 bps (60%) | Source can hold up to 60% of vault TVL |
| 4,001 – 7,000 | 4,000 bps (40%) | Source limited to 40% |
| 7,001 – 10,000 | 2,000 bps (20%) | Source limited to 20% |

### Layer 3: Stressed LCR → Action Decision

CRE computes a global stressed LCR using a 30% redemption shock assumption:

```
stressedOutflows = pendingWithdrawals + totalAssets × 3000 / 10000
stressedLCR = totalHQLA × 10000 / stressedOutflows
```

The stressed LCR determines which action CRE sends to the vault:

| Stressed LCR | System Status | Action |
|-------------|---------------|--------|
| >= 15,000 (150%) | GREEN | Update params (routine) |
| 12,000 – 14,999 (120-150%) | YELLOW | Update params (tighten) |
| 10,000 – 11,999 (100-120%) | ORANGE | Defensive rebalance (pull capital from riskiest source) |
| < 10,000 (< 100%) | RED | Emergency pause |

### Worked Example: End-to-End

**On-chain readings:**

```
Aave utilization: 8500 bps (85%)
Aave available liquidity: 2,000,000 USDC
Aave oracle deviation: 100 bps (1%)
Vault Aave balance: 500,000 USDC
Vault total assets: 1,000,000 USDC
```

**Step 1 — Sub-scores:**

```
utilizationRisk  = 3,000       (85% falls in the 80-90% bracket)
liquidityRisk    = min(500,000 × 10,000 / 2,000,000, 10000) = 2,500
oracleRisk       = min(100 × 20, 10000) = 2,000
concentrationRisk = 500,000 × 10,000 / 1,000,000 = 5,000
```

**Step 2 — Composite score:**

```
score = (3,000 × 3,500 + 2,500 × 3,000 + 2,000 × 2,000 + 5,000 × 1,500) / 10,000
      = (10,500,000 + 7,500,000 + 4,000,000 + 7,500,000) / 10,000
      = 2,950
```

**Step 3 — Map to outputs (score = 2,950):**

```
Haircut         → 1,500 bps (15%)   [score 2,000-3,999 bracket]
Stress outflow  → 2,000 bps (20%)   [score 2,000-3,999 bracket]
Max concentration → 6,000 bps (60%) [score 0-4,000 bracket]
Risk tier       → YELLOW (1)
```

**Step 4 — These parameters are sent to the vault via `onReport()` and used in:**

```
computeLCR():
  Aave HQLA = 500,000 × (10,000 - 1,500) / 10,000 = 425,000
  Aave stressed outflow = 500,000 × 2,000 / 10,000 = 100,000

deployToYield():
  If operator tries to put > 60% of TVL into Aave → revert ConcentrationBreached()
  If resulting LCR < lcrFloorBps → revert LCRBreached()
```

---

## 17. RBAC (Role-Based Access Control)

**What it is:** A lightweight role system. The operator implicitly has all roles. Additional addresses can be granted specific roles (e.g., `ROLE_GUARDIAN` for emergency pause/unpause).

**Source:** `StreamVault.sol`

### Logic

```
modifier onlyRole(bytes32 role):
    IF msg.sender ≠ operator AND !_roles[role][msg.sender]:
        REVERT OnlyOperator()

pause() / unpause() require: onlyRole(ROLE_GUARDIAN)
All other admin functions require: onlyOperator
```

### Example

```
Operator grants guardian role to a multisig:
  vault.grantRole(ROLE_GUARDIAN, multisigAddress)

Multisig can now call:
  vault.pause()    ✓
  vault.unpause()  ✓

Multisig CANNOT call:
  vault.deployToYield(...)  🛑 OnlyOperator
  vault.setDepositCap(...)  🛑 OnlyOperator

Operator can still pause/unpause (implicit role).
```

---

## 18. EIP-712 Gasless Operator Approval

**What it is:** Users can sign an off-chain EIP-712 typed message to approve an EIP-7540 operator, and a relayer can submit it on their behalf. The user pays no gas.

**Source:** `StreamVault.sol`

### Formula

```
structHash = keccak256(abi.encode(
    SET_OPERATOR_TYPEHASH,
    signer,
    operator,
    approved,
    nonces[signer]++,    // auto-increment prevents replay
    deadline
))

digest = EIP-712 domain separator ‖ structHash
recoveredSigner = ecrecover(digest, v, r, s)

REQUIRE: recoveredSigner == signer
REQUIRE: block.timestamp ≤ deadline
```

### Example

```
Alice wants to approve Bob as her EIP-7540 operator but has no ETH for gas.

1. Alice signs off-chain (in her wallet):
   {
     owner: alice,
     operator: bob,
     approved: true,
     nonce: 0,
     deadline: block.timestamp + 1 hour
   }
   → produces (v, r, s) signature

2. Relayer submits on-chain:
   vault.setOperatorWithSig(alice, bob, true, deadline, v, r, s)

3. Vault verifies:
   - Recovers signer from (v, r, s) → matches alice ✓
   - block.timestamp ≤ deadline ✓
   - Nonce was 0, now incremented to 1 (replay protection) ✓

4. Bob is now alice's EIP-7540 operator.
   Bob can call vault.requestRedeem(shares, alice, alice) on her behalf.

If relayer replays the same (v, r, s):
   nonces[alice] is now 1, but signature was for nonce 0
   → ecrecover returns wrong address → REVERT InvalidSigner() 🛑
```

---

## Constants Reference

| Constant | Value | Meaning |
|---|---|---|
| `MAX_YIELD_SOURCES` | 20 | Maximum registered yield source adapters |
| `MAX_PERFORMANCE_FEE_BPS` | 5,000 | 50% max performance fee |
| `MAX_MANAGEMENT_FEE_BPS` | 500 | 5% max annual management fee |
| `MIN_SMOOTHING_PERIOD` | 300 | 5 minutes minimum EMA smoothing |
| `MAX_SMOOTHING_PERIOD` | 86,400 | 24 hours maximum EMA smoothing |
| `EMA_FLOOR_BPS` | 9,500 | EMA ≥ 95% of spot price |
| `SECONDS_PER_YEAR` | 31,557,600 | 365.25 days (accounts for leap years) |
| `MIN_EPOCH_DURATION` | 300 | 5 minutes minimum before settlement |
| `MAX_DRAWDOWN_BPS` | 5,000 | 50% max configurable drawdown threshold |
| `DEFAULT_MAX_DRAWDOWN_BPS` | 1,000 | 10% default drawdown circuit breaker |
| `MAX_WITHDRAWAL_FEE_BPS` | 100 | 1% max exit fee |
| `MAX_LOCKUP_PERIOD` | 604,800 | 7 days max deposit lockup |
| `MIN_TIMELOCK_DELAY` | 3,600 | 1 hour minimum timelock |
| `MAX_TIMELOCK_DELAY` | 604,800 | 7 days maximum timelock |
| `MAX_HAIRCUT_BPS` | 9,500 | 95% max LCR haircut per source |
| `_decimalsOffset()` | 3 | 10³ = 1000 virtual shares/assets |

### Default Risk Parameters (per source)

| Parameter | Default | Meaning |
|---|---|---|
| `liquidityHaircutBps` | 1,000 | 10% haircut |
| `stressOutflowBps` | 3,000 | 30% stress outflow |
| `maxConcentrationBps` | 10,000 | 100% (no concentration limit) |
| `riskTier` | 0 | GREEN |
