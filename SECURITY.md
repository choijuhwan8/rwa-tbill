# Security review — sgTBILL

Phase 6 self-review of the sgTBILL contracts: static analysis (Slither, forge lint), property-based testing (fuzz + stateful invariants), and a manual pass over the economic attack surface. **This is a learning project, not an audited protocol. Do not use it with real funds.**

| | |
|---|---|
| Scope | `src/Vault.sol`, `src/TBillToken.sol`, `src/Whitelist.sol`, `src/MockUSDC.sol`, `script/Deploy.s.sol` |
| Compiler | solc 0.8.24, optimizer 200 runs |
| Dependencies | OpenZeppelin Contracts v5.6.1, forge-std v1.16.2 |
| Tools | Slither 0.11.6 (102 detectors), Foundry 1.8.6 (`forge lint`, fuzzing, invariant testing, coverage) |

## Summary

| ID | Title | Severity | Status |
|---|---|---|---|
| F-1 | First-depositor donation can skim a victim's rounding loss | Low | Accepted, bounded (fixed in practice by F-2) |
| F-2 | Dust-supply griefing: deposits can be blocked for free | Medium | **Fixed** (dead-shares seeding in deploy) |
| F-3 | Unbounded yield rate lets a yield admin mint without limit | Medium | **Fixed** (`MAX_YIELD_BPS` = 20%) |
| F-4 | No emergency stop | Low | **Fixed** (`Pausable`, `PAUSER_ROLE`) |
| F-5 | State written after external call in `setYieldRate` | Informational | **Fixed** (checkpoint / mint split) |
| F-6 | Missing zero-address validation in constructors | Informational | **Fixed** |
| F-7 | `TBillToken.whitelist` not immutable | Gas | **Fixed** |
| F-8 | Centralisation: single EOA holds every admin role | Informational | Acknowledged (see recommendations) |
| F-9 | De-whitelisted holders cannot redeem | Informational | By design (documented) |

Results:

- **Slither:** 9 findings at the start of Phase 6, 0 now. Every remaining suppression is annotated inline with its reason.
- **Tests:** 61, including 4 fuzz tests and 4 stateful invariants (~128k random calls per run, zero reverts).
- **Coverage:** 100% of lines, statements and functions in `src/`, and 88% of branches.

---

## Findings

### F-1 — First-depositor donation can skim a victim's rounding loss (Low)

This is the classic ERC-4626 "inflation" attack. The attacker deposits 1 base unit (1e-6 mUSDC), then sends mUSDC straight to the vault. That raises `totalAssets()` without minting any shares. A victim's next deposit rounds down in the vault's favour, and the attacker, as the only other holder, collects the difference.

**Analysis.** NAV is computed as `assets × 10¹² × 10¹⁸ / supply`. The 6→18 decimal `SCALE` means 1 base unit mints 10¹² share-units, so it acts as a built-in 12-decimal virtual offset. The victim loses at most one share-unit's worth of value, which works out to `(1 + donation) / 10¹²` base units.

`testFuzz_DonationAttackBounded` found that profit is possible but tiny: **7 micro-USDC against an $8.8M donation**. Stealing $1 would mean parking about $1 trillion in the vault.

**Status.** Accepted. The bound is asserted by fuzz test. With F-2's seed in place the attacker is never the sole holder, so most of any donation goes to the dead shares and the attack loses money.

### F-2 — Dust-supply griefing: deposits can be blocked for free (Medium) — FIXED

**Found by:** the stateful invariant suite. Once `fail_on_revert` was turned on, the fuzzer shrank a failing run to five calls:

```
deposit → transferShares (7,952 share-units to a second actor) → redeem (100% of the first actor)
       → accrueYield ($100k) → deposit ($1)   ⟶  reverts: "shares rounded to zero"
```

When total supply falls to a few share-units (a fresh vault, or everyone has exited), any increase in assets pushes NAV to astronomical values. Every ordinary deposit then mints 0 shares and reverts. The asset increase can come from a donation, a manual `accrueYield`, or time-based accrual.

Done on purpose, this costs the attacker nothing. They keep one share-unit, donate $D, and block every deposit below $D. As the sole holder, they redeem the donation back whenever they like. `test_DustSupplyGriefsDepositsWithoutSeed` reproduces it: a $1,000 donation blocks a $999 deposit, then comes back to the attacker in full.

**Fix.** `script/Deploy.s.sol` seeds the vault with dead shares at deployment, the same idea as Uniswap V2's `MINIMUM_LIQUIDITY`. It deposits 1 mUSDC and transfers the resulting 1.0 sgTBILL to `0x…dEaD`, which is whitelisted so it can receive. Nobody holds that key, so total supply can never drop below 10¹⁸. Blocking a $1 deposit would now take about $10¹⁸ of assets. `test_DeadSharesNeutraliseDustGriefing` shows deposits keep working after the same attack. The invariant suite runs against the seeded setup with `fail_on_revert = true` and completes with zero reverts.

**Residual risk.** The fix lives in the deploy script, not in the contract. A deployment that skips the seed is still vulnerable. Moving this into the contract (mint locked shares on the first deposit, or use OZ ERC-4626-style virtual shares) is the stronger fix. It wasn't done here because it changes the NAV formula that 19 existing tests check exactly.

### F-3 — Unbounded yield rate (Medium) — FIXED

Time-based yield is *minted* (`MockUSDC.mint`), not transferred in, and `setYieldRate` accepted any value. A compromised or fat-fingered `YIELD_ADMIN_ROLE` key could set, say, 1,000,000% and inflate NAV without limit. Anyone redeeming would then pull real value out against freshly printed assets.

**Fix.** Added `MAX_YIELD_BPS = 2_000` (20%) and `require(bps <= MAX_YIELD_BPS, "rate too high")`. Covered by unit tests (`test_RateAtCapAllowed`, `test_RateAboveCapReverts`) and the invariant `invariant_RateWithinCap`. The frontend reads the cap from the contract and rejects higher input.

### F-4 — No emergency stop (Low) — FIXED

Tokenized funds need a way to halt subscriptions and redemptions during a custodian incident or a NAV dispute.

**Fix.** `Vault` now inherits OpenZeppelin `Pausable`. `deposit` and `redeem` are `whenNotPaused`, and `pause`/`unpause` require the new `PAUSER_ROLE`. Yield keeps accruing while paused, so holders lose nothing; they just can't exit until the vault is unpaused (`test_YieldKeepsAccruingWhilePaused`). Admin and compliance functions keep working.

### F-5 — State written after external call in `setYieldRate` (Informational) — FIXED

Slither `reentrancy-no-eth`: `setYieldRate` called `_realizeYield()`, which mints through an external call, and only then wrote `annualYieldRateBps`. `usdc` is an immutable, trusted token, so this wasn't exploitable. It still broke checks-effects-interactions.

**Fix.** Settlement is split into `_checkpointYield()` (pure effects: compute what's owed at the old rate and advance the clock) and `_mintYield()` (the interaction). `setYieldRate` now checkpoints, stores the new rate, and only then mints. `setYieldRate` and `accrueYield` also gained `nonReentrant` as defence in depth.

### F-6 — Missing zero-address validation (Informational) — FIXED

`Vault(usdc, shareToken)` and `TBillToken(whitelist)` accepted `address(0)`, which would brick the deployment because the addresses are immutable. Both constructors now `require` non-zero addresses.

### F-7 — `TBillToken.whitelist` should be immutable (Gas) — FIXED

Slither `immutable-states`. The token reads it on every transfer, so making it `immutable` saves an SLOAD (~2,100 gas cold) per transfer, mint and burn.

### F-8 — Centralisation (Informational) — Acknowledged

The deployer EOA holds `DEFAULT_ADMIN_ROLE`, `COMPLIANCE_ROLE`, `YIELD_ADMIN_ROLE` and `PAUSER_ROLE`, and the `MockUSDC` admin role. That's expected for a demo, and it mirrors how permissioned RWA funds actually work: the issuer is a trusted party. For production:

- Put `DEFAULT_ADMIN_ROLE` behind a multisig (e.g. Safe) and use `AccessControlDefaultAdminRules` for two-step, time-delayed admin transfers.
- Give each operational role its own key: compliance officer, NAV/yield operator, guardian/pauser.
- Put rate changes behind a timelock so holders can react.

### F-9 — De-whitelisted holders cannot redeem (Informational) — By design

`TBillToken._update` checks the whitelist on burns too. A holder removed from the whitelist therefore can't redeem, and their position is effectively frozen. That is the intended compliance behaviour (e.g. a sanctions hit). A production fund would also need a privileged forced-redemption or forced-transfer path, as in ERC-3643 `forcedTransfer`, so the issuer can return funds to a frozen investor's verified account.

---

## Static analysis

### Slither

```
slither .        # config in slither.config.json (excludes lib/, test/, script/)
```

| Detector | Before | After | Resolution |
|---|---|---|---|
| `reentrancy-no-eth` | 1 | 0 | Fixed (F-5) |
| `immutable-states` | 1 | 0 | Fixed (F-7) |
| `incorrect-equality` | 2 | 0 | False positive, annotated. `elapsed == 0` / `yieldAmount == 0` are no-op guards, not deadlines or balance checks. |
| `timestamp` | 2 | 0 | Accepted, annotated. Accrual is inherently time-based. A validator moving `block.timestamp` by a few seconds shifts yield by `assets × rate × seconds / year`, which is negligible. |
| `reentrancy-events` | 3 | 0 | Accepted, annotated. The only external call before the event is a mint on the immutable, trusted `usdc`. `YieldAccrued` reports post-mint NAV, so it has to come after the mint. |
| **Total** | **9** | **0** | |

CI runs `slither . --fail-low`, so any new finding fails the build.

### forge lint

The remaining notes are informational and covered above: `block-timestamp` (accepted), `reentrancy-events` (accepted; deposit and redeem events follow the token transfers, and all calls are to trusted tokens behind `nonReentrant`), and `missing-events-arithmetic`, which is a false positive because `YieldRateSet(old, new)` is emitted on every rate change. In tests, `vm.warp(block.timestamp + …)` was replaced with forge-std's `skip(…)`, fixing `environment-read-across-mutation`.

## Testing

| Suite | Tests | Covers |
|---|---|---|
| `Vault.t.sol` | 19 | NAV maths, deposit/redeem, decimals scaling, manual and time-based yield, rate-change settlement, reentrancy (malicious token) |
| `VaultHardening.t.sol` | 13 | Pause, rate cap, constructor validation, fuzz: round trip never profits, split redemption no better than whole, donation attack bounded, F-2 reproduction and fix |
| `TBillToken.t.sol` | 11 | Role-gated mint/burn, whitelist enforcement on mint, transfer and burn |
| `Whitelist.t.sol` | 8 | Add/remove, events, duplicate guards, role gating, role delegation |
| `Deploy.t.sol` | 5 | Deploy script wiring, roles, seed shares, end-to-end deposit |
| `MockUSDC.t.sol` | 4 | Decimals, faucet |
| `invariant/VaultInvariant.t.sol` | 4 invariants | See below |

**Stateful invariants.** A handler runs random sequences of deposits, partial redemptions, share transfers, time jumps (up to 400 days), rate changes and yield injections across four actors. It runs with `fail_on_revert = true`: every handler action is a valid operation, so any revert counts as a bug. That setting is what surfaced F-2. After every call:

1. **Supply conservation.** The sum of all balances equals `totalSupply()`.
2. **Solvency.** If every holder redeemed at the current NAV, the vault could pay all of them.
3. **NAV monotonicity.** No action ever lowers NAV for existing holders. Deposit and redeem rounding always favours the vault, and yield is never negative.
4. **Rate cap.** `annualYieldRateBps ≤ MAX_YIELD_BPS`.

**Coverage** (`forge coverage --no-match-coverage "script|test"`):

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `MockUSDC.sol` | 100% | 100% | n/a | 100% |
| `TBillToken.sol` | 100% | 100% | 100% | 100% |
| `Vault.sol` | 100% | 100% | 83% | 100% |
| `Whitelist.sol` | 100% | 100% | 100% | 100% |

## Known limitations (not bugs, but not production-ready)

- **Yield is simulated** by minting `MockUSDC`. A real fund would have the custodian or transfer agent pay coupons in (the `accrueYield` path) or an oracle would report NAV. The vault would hold no mint rights over a real stablecoin.
- **Simple interest, ACT/365.** It doesn't compound between settlements. Real money-market funds accrue daily and compound.
- **Synchronous redemptions at on-chain NAV.** Real T-bill funds settle T+0/T+1 against an off-chain NAV strike, and can gate redemptions when liquidity is short.
- **Open faucet.** `MockUSDC.faucet` is unrestricted on purpose (testnet play money). It can only credit the caller, so it can't move NAV.
