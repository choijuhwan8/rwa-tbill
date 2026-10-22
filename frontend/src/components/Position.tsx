"use client";

import { parseUnits } from "viem";
import { mockUSDCAbi } from "@/lib/abis";
import { fmtShares, fmtUsdc } from "@/lib/format";
import { useDeployment, useFund, usePosition, useTx } from "@/lib/hooks";
import { Button, Card, Stat, TxStatus } from "./ui";

const FAUCET_AMOUNT = parseUnits("1000", 6);

export function Position() {
  const d = useDeployment()!;
  const p = usePosition();
  const f = useFund();
  const tx = useTx();

  // shares (18dp) × NAV (18dp) → USDC (6dp)
  const value =
    p.shareBalance !== undefined && f.liveNav !== undefined
      ? (p.shareBalance * f.liveNav) / 10n ** 18n / 10n ** 12n
      : undefined;

  return (
    <Card
      title="Your position"
      aside={
        p.isWhitelisted === undefined ? null : p.isWhitelisted ? (
          <span className="rounded-full bg-positive/15 px-2.5 py-0.5 text-xs font-medium text-positive">
            KYC verified
          </span>
        ) : (
          <span className="rounded-full bg-warning/15 px-2.5 py-0.5 text-xs font-medium text-warning">
            Not whitelisted
          </span>
        )
      }
    >
      <div className="grid grid-cols-2 gap-5 sm:grid-cols-3">
        <Stat label="sgTBILL" value={fmtShares(p.shareBalance)} />
        <Stat label="Value" value={`$${fmtUsdc(value, 6)}`} sub="at live NAV" />
        <Stat label="mUSDC wallet" value={fmtUsdc(p.usdcBalance)} />
      </div>

      {p.isWhitelisted === false && (
        <p className="mt-4 text-sm text-muted">
          sgTBILL is a permissioned token: only whitelisted (KYC&apos;d) addresses can hold it. Ask the compliance admin
          to whitelist <span className="font-mono">{p.address}</span> before depositing.
        </p>
      )}

      <div className="mt-5 flex flex-wrap items-center gap-3 border-t border-border pt-4">
        <Button
          variant="secondary"
          disabled={tx.busy}
          onClick={() =>
            tx.run([
              {
                label: "Faucet",
                send: (w) => w({ address: d.usdc, abi: mockUSDCAbi, functionName: "faucet", args: [FAUCET_AMOUNT] }),
              },
            ])
          }
        >
          Get 1,000 test mUSDC
        </Button>
        <span className="text-xs text-muted">Play money: the mock stablecoin has an open faucet.</span>
      </div>
      <TxStatus state={tx.state} />
    </Card>
  );
}
