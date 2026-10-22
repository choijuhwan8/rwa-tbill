"use client";

import { useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { mockUSDCAbi, vaultAbi } from "@/lib/abis";
import { fmtShares, fmtUsdc, SHARE_DECIMALS, USDC_DECIMALS } from "@/lib/format";
import { useDeployment, useFund, usePosition, useTx, type TxStep } from "@/lib/hooks";
import { Button, Card, Input, TxStatus } from "./ui";

const E18 = 10n ** 18n;
const SCALE = 10n ** 12n;

function parse(value: string, decimals: number) {
  try {
    return value.trim() ? parseUnits(value.trim(), decimals) : 0n;
  } catch {
    return undefined; // malformed input
  }
}

export function Trade() {
  const [mode, setMode] = useState<"deposit" | "redeem">("deposit");
  const [amount, setAmount] = useState("");
  const d = useDeployment()!;
  const p = usePosition();
  const f = useFund();
  const tx = useTx();

  const isDeposit = mode === "deposit";
  const parsed = parse(amount, isDeposit ? USDC_DECIMALS : SHARE_DECIMALS);
  const balance = isDeposit ? p.usdcBalance : p.shareBalance;

  // Preview at the live NAV: the vault settles pending yield before pricing, so this is
  // what the transaction will actually use (modulo a few seconds of extra accrual).
  const preview =
    parsed && f.liveNav
      ? isDeposit
        ? (parsed * SCALE * E18) / f.liveNav
        : (parsed * f.liveNav) / E18 / SCALE
      : undefined;

  const error = f.paused
    ? "Vault is paused"
    : parsed === undefined
      ? "Invalid amount"
      : balance !== undefined && parsed > balance
        ? "Insufficient balance"
        : isDeposit && p.isWhitelisted === false
          ? "Your address is not whitelisted"
          : undefined;

  async function submit() {
    if (!parsed) return;
    const steps: TxStep[] = [];
    if (isDeposit) {
      if ((p.allowance ?? 0n) < parsed) {
        steps.push({
          label: "Approve mUSDC",
          send: (w) => w({ address: d.usdc, abi: mockUSDCAbi, functionName: "approve", args: [d.vault, parsed] }),
        });
      }
      steps.push({
        label: "Deposit",
        send: (w) => w({ address: d.vault, abi: vaultAbi, functionName: "deposit", args: [parsed] }),
      });
    } else {
      steps.push({
        label: "Redeem",
        send: (w) => w({ address: d.vault, abi: vaultAbi, functionName: "redeem", args: [parsed] }),
      });
    }
    if (await tx.run(steps)) setAmount("");
  }

  const needsApproval = isDeposit && parsed !== undefined && parsed > 0n && (p.allowance ?? 0n) < parsed;

  return (
    <Card title="Trade">
      <div className="mb-4 inline-flex rounded-lg border border-border p-0.5" role="tablist">
        {(["deposit", "redeem"] as const).map((m) => (
          <button
            key={m}
            role="tab"
            aria-selected={mode === m}
            onClick={() => {
              setMode(m);
              setAmount("");
              tx.reset();
            }}
            className={`rounded-md px-4 py-1.5 text-sm font-medium capitalize ${
              mode === m ? "bg-accent text-accent-foreground" : "text-muted hover:text-foreground"
            }`}
          >
            {m}
          </button>
        ))}
      </div>

      <label className="block text-xs text-muted" htmlFor="amount">
        {isDeposit ? "You pay (mUSDC)" : "You redeem (sgTBILL)"}
      </label>
      <div className="mt-1 flex gap-2">
        <Input
          id="amount"
          inputMode="decimal"
          placeholder="0.00"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <Button
          variant="secondary"
          onClick={() =>
            balance !== undefined && setAmount(formatUnits(balance, isDeposit ? USDC_DECIMALS : SHARE_DECIMALS))
          }
        >
          Max
        </Button>
      </div>
      <div className="mt-1 text-xs text-muted">
        Balance: {isDeposit ? `${fmtUsdc(balance)} mUSDC` : `${fmtShares(balance)} sgTBILL`}
      </div>

      <div className="mt-4 flex items-baseline justify-between rounded-lg bg-background px-3 py-2.5 text-sm">
        <span className="text-muted">You receive (est.)</span>
        <span className="font-mono tabular-nums">
          {preview === undefined ? "—" : isDeposit ? `${fmtShares(preview)} sgTBILL` : `${fmtUsdc(preview, 6)} mUSDC`}
        </span>
      </div>

      <Button className="mt-4 w-full" disabled={!parsed || !!error || tx.busy} onClick={submit}>
        {error && parsed ? error : needsApproval ? "Approve & deposit" : isDeposit ? "Deposit" : "Redeem"}
      </Button>
      {needsApproval && !error && (
        <p className="mt-2 text-xs text-muted">Two transactions: an mUSDC approval, then the deposit.</p>
      )}
      <TxStatus state={tx.state} />
    </Card>
  );
}
