# rwa-tbill

Mock tokenized T-bill fund ("sgTBILL") — ERC-20 + compliance whitelist + NAV vault + yield accrual, built with Foundry.

A learning/portfolio project exploring real-world asset (RWA) tokenization: fractional ownership, permissioned transfers, issuance/redemption at NAV, and yield accrual — the mechanics behind products like BlackRock BUIDL, Franklin Templeton FOBXX, and Ondo OUSG.

## Stack

- **Foundry** (forge / cast / anvil / chisel) — build, test, deploy
- **OpenZeppelin Contracts** v5 — audited base contracts
- **Solidity** 0.8.24

## Usage

```shell
forge build          # compile
forge test -vv       # run tests (verbose)
anvil                # start a local chain (separate terminal)
```

## Status

- ✅ **Phase 0** — Foundry environment setup, tooling, local deploy loop
- ✅ **Phase 1** — `MockUSDC` + `TBillToken` (ERC-20 + AccessControl)
- ✅ **Phase 2** — `Whitelist` compliance layer (permissioned transfers)
- ✅ **Phase 3** — `Vault` (deposit / redeem / NAV accounting)
- ✅ **Phase 4** — yield accrual (manual `accrueYield` + time-based continuous accrual with lazy settlement)
- ⬜ Phase 5 — Next.js frontend, deploy to Sepolia
- ⬜ Phase 6 — Slither hardening + writeup
