# rwa-tbill

Mock tokenized T-bill fund ("sgTBILL") — ERC-20 + compliance whitelist + NAV vault + yield accrual, built with Foundry, with a Next.js dApp on top.

A learning/portfolio project exploring real-world asset (RWA) tokenization: fractional ownership, permissioned transfers, issuance/redemption at NAV, and yield accrual — the mechanics behind products like BlackRock BUIDL, Franklin Templeton FOBXX, and Ondo OUSG.

> Educational demo for testnets only. mUSDC is play money and yield is simulated. Not a security, not investment advice.

## How it works

```
             approve + deposit(usdc)                     mint(shares)
  Investor ───────────────────────────▶  Vault  ──────────────────────────▶  TBillToken (sgTBILL)
     ▲        ◀───────────────────────   (NAV)   ◀─────────────────────────   ERC-20, 18 dp
     │            redeem(shares) → usdc    │                burn(shares)          │ every mint / burn /
     │                                     │ mints simulated                      │ transfer checks
     │                                     ▼ T-bill interest                      ▼
     └── faucet ───────────────────  MockUSDC (mUSDC)                        Whitelist (KYC)
                                      ERC-20, 6 dp                          COMPLIANCE_ROLE
```

| Contract | Role |
|---|---|
| [`MockUSDC`](src/MockUSDC.sol) | 6-decimal stablecoin stand-in. Open `faucet`, and a role-gated `mint` used by the vault to simulate interest. |
| [`Whitelist`](src/Whitelist.sol) | KYC registry. `COMPLIANCE_ROLE` adds and removes investors. |
| [`TBillToken`](src/TBillToken.sol) | sgTBILL fund share. Only the vault can mint or burn, and every mint, burn and transfer requires both sides to be whitelisted. |
| [`Vault`](src/Vault.sol) | Issues and redeems shares at NAV, accrues yield, and can be paused. |

**NAV.** `navPerToken = totalAssets × 10¹² × 10¹⁸ / totalSupply`. The 10¹² bridges USDC's 6 decimals to the share token's 18. Deposits mint `usdc / NAV` shares and redemptions pay `shares × NAV`. Both round down, in the vault's favour.

**Yield.** The `YIELD_ADMIN_ROLE` sets an annual rate (in basis points, capped at 20%). Interest is simple, on an ACT/365 basis, and settled lazily: each deposit, redeem or rate change first mints the yield owed since the last settlement, so newcomers can't dilute yield that was earned before they arrived. `pendingYield()` exposes the unsettled amount, and the dApp adds it in to show a live NAV. Real coupons can also be paid in with `accrueYield`.

**Compliance.** Shares can only be held by whitelisted addresses. A de-whitelisted holder can't transfer *or* redeem: their position is frozen, which is how permissioned funds handle sanctions hits.

**Safety.** Pausable deposits and redemptions (`PAUSER_ROLE`), a rate cap, reentrancy guards, and checks-effects-interactions ordering. The deploy script locks 1 seed share at a burn address to defeat first-depositor griefing. See **[SECURITY.md](SECURITY.md)** for the full review.

## Stack

- **Contracts:** Solidity 0.8.24, OpenZeppelin Contracts v5, Foundry (forge / cast / anvil)
- **Frontend:** Next.js 16 (App Router), React 19, wagmi v3 + viem, TanStack Query, Tailwind v4
- **Security:** Slither, forge lint, fuzz + stateful invariant tests, all in CI

## Quick start (local)

Prerequisites: [Foundry](https://getfoundry.sh) and Node 20+.

```shell
forge build && forge test          # 61 tests incl. fuzz + invariants
```

Run the whole stack on a local chain, using three terminals:

```shell
# 1. local chain
anvil

# 2. deploy (anvil's default account is unlocked, so no key is needed)
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# 3. dApp
cd frontend && npm install && npm run dev     # http://localhost:3000
```

In the dApp, click **Anvil dev account** (dev builds only) to act as the deployer without MetaMask. It's already whitelisted and holds every admin role. Then try: **Get 1,000 test mUSDC** → **Deposit** → **+1 year** (time travel, local chain only) → watch NAV reach 1.05 → **Redeem**.

To use MetaMask on the local chain instead, add the network (RPC `http://127.0.0.1:8545`, chain ID 31337) and import one of the test keys anvil prints.

## Deploy to Sepolia

1. Configure:
   ```shell
   cp .env.example .env               # fill SEPOLIA_RPC_URL and ETHERSCAN_API_KEY
   cast wallet import deployer --interactive   # stores your key encrypted, never in .env
   ```
   The deployer account needs a little Sepolia ETH (about 0.01) from a faucet.

2. Deploy and verify:
   ```shell
   source .env
   forge script script/Deploy.s.sol --rpc-url sepolia --account deployer --broadcast --verify
   ```
   This deploys and wires all four contracts, whitelists the deployer (plus any `WHITELIST=` addresses), locks the seed share, sets a 5% rate, and writes `frontend/src/deployments/11155111.json`.

3. Point the dApp at it:
   ```shell
   cd frontend && npm run sync        # regenerates the deployments index (and ABIs)
   ```
   With a Sepolia deployment present, the dApp reads Sepolia by default. Commit the JSON.

4. Host the frontend, for example on [Vercel](https://vercel.com): import the repo, set **Root Directory** to `frontend`, and optionally set `NEXT_PUBLIC_SEPOLIA_RPC_URL`.

Visitors connect with MetaMask on Sepolia. To deposit, the deployer whitelists them in the dApp's **Admin → Compliance** panel. Anyone can use the mUSDC faucet.

## Project layout

```
src/                   contracts
script/Deploy.s.sol    deploy + wire + seed; writes addresses for the frontend
test/                  unit, fuzz (VaultHardening) and invariant (invariant/) tests
frontend/              Next.js dApp
  src/lib/abis.ts        generated typed ABIs (npm run sync)
  src/deployments/       <chainId>.json written by the deploy script
SECURITY.md            Phase 6 security review
```

## Status

- ✅ **Phase 0:** Foundry environment setup, tooling, local deploy loop
- ✅ **Phase 1:** `MockUSDC` + `TBillToken` (ERC-20 + AccessControl)
- ✅ **Phase 2:** `Whitelist` compliance layer (permissioned transfers)
- ✅ **Phase 3:** `Vault` (deposit / redeem / NAV accounting)
- ✅ **Phase 4:** yield accrual (manual `accrueYield` + time-based continuous accrual with lazy settlement)
- ✅ **Phase 5:** deploy script, Next.js + wagmi dApp, Sepolia deployment flow
- ✅ **Phase 6:** Slither (9 → 0 findings), fuzz + invariant testing, hardening (pause, rate cap, dead-share seeding), [security writeup](SECURITY.md)

## Ideas for next steps

- Move dead-share protection into the contract itself (virtual shares, ERC-4626 style)
- Implement the ERC-4626 interface so the vault composes with DeFi tooling
- ERC-3643-style forced transfers for frozen investors; multisig + timelocked admin roles
- Asynchronous (T+1) redemptions against an oracle-reported NAV
