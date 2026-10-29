"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { isAddress } from "viem";
import { useChainId } from "wagmi";
import { foundry } from "wagmi/chains";
import { vaultAbi, whitelistAbi } from "@/lib/abis";
import { fmtBps } from "@/lib/format";
import { useDeployment, useFund, usePosition, useTx } from "@/lib/hooks";
import { Button, Card, Input, TxStatus } from "./ui";

function WhitelistAdmin() {
  const d = useDeployment()!;
  const f = useFund();
  const tx = useTx();
  const toggle = useTx();
  const [addr, setAddr] = useState("");
  const valid = isAddress(addr);

  const send = (fn: "addToWhitelist" | "removeFromWhitelist") =>
    valid &&
    tx.run([
      {
        label: fn === "addToWhitelist" ? "Whitelist" : "Remove",
        send: (w) => w({ address: d.whitelist, abi: whitelistAbi, functionName: fn, args: [addr] }),
      },
    ]);

  return (
    <div>
      <h3 className="text-sm font-medium">Compliance: whitelist</h3>
      <p className="mt-0.5 text-xs text-muted">Only whitelisted addresses can receive, hold or send sgTBILL.</p>
      <Input className="mt-2" placeholder="0x…" value={addr} onChange={(e) => setAddr(e.target.value)} />
      <div className="mt-2 flex gap-2">
        <Button disabled={!valid || tx.busy} onClick={() => send("addToWhitelist")}>
          Add
        </Button>
        <Button variant="secondary" disabled={!valid || tx.busy} onClick={() => send("removeFromWhitelist")}>
          Remove
        </Button>
      </div>
      <TxStatus state={tx.state} />
      <label className="mt-4 flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={!!f.selfService}
          disabled={f.selfService === undefined || toggle.busy}
          onChange={(e) =>
            toggle.run([
              {
                label: e.target.checked ? "Enable self-service" : "Disable self-service",
                send: (w) =>
                  w({
                    address: d.whitelist,
                    abi: whitelistAbi,
                    functionName: "setSelfService",
                    args: [e.target.checked],
                  }),
              },
            ])
          }
        />
        Self-service demo KYC
      </label>
      <p className="mt-0.5 text-xs text-muted">Lets visitors whitelist themselves. Removed addresses stay blocked.</p>
      <TxStatus state={toggle.state} />
    </div>
  );
}

function YieldAdmin() {
  const d = useDeployment()!;
  const f = useFund();
  const tx = useTx();
  const [pct, setPct] = useState("");
  const bps = Math.round(Number(pct) * 100);
  const max = Number(f.maxRateBps ?? 0n);
  const valid = pct.trim() !== "" && Number.isFinite(bps) && bps >= 0 && bps <= max;

  return (
    <div>
      <h3 className="text-sm font-medium">Yield rate</h3>
      <p className="mt-0.5 text-xs text-muted">
        Current {fmtBps(f.rateBps)}, capped at {fmtBps(f.maxRateBps)}. Changing it first settles accrued yield at the
        old rate.
      </p>
      <div className="mt-2 flex gap-2">
        <Input placeholder="e.g. 5.25" inputMode="decimal" value={pct} onChange={(e) => setPct(e.target.value)} />
        <Button
          className="whitespace-nowrap"
          disabled={!valid || tx.busy}
          onClick={() =>
            tx.run([
              {
                label: "Set rate",
                send: (w) => w({ address: d.vault, abi: vaultAbi, functionName: "setYieldRate", args: [BigInt(bps)] }),
              },
            ])
          }
        >
          Set %
        </Button>
      </div>
      <TxStatus state={tx.state} />
    </div>
  );
}

function PauseAdmin() {
  const d = useDeployment()!;
  const f = useFund();
  const tx = useTx();
  const fn = f.paused ? "unpause" : "pause";

  return (
    <div>
      <h3 className="text-sm font-medium">Emergency pause</h3>
      <p className="mt-0.5 text-xs text-muted">
        {f.paused ? "Paused: deposits and redemptions are halted." : "Halts deposits and redemptions."}
      </p>
      <Button
        className="mt-2"
        variant={f.paused ? "primary" : "secondary"}
        disabled={f.paused === undefined || tx.busy}
        onClick={() =>
          tx.run([
            {
              label: f.paused ? "Unpause" : "Pause",
              send: (w) => w({ address: d.vault, abi: vaultAbi, functionName: fn }),
            },
          ])
        }
      >
        {f.paused ? "Unpause vault" : "Pause vault"}
      </Button>
      <TxStatus state={tx.state} />
    </div>
  );
}

const DAY = 86_400;

/** Anvil-only: jump chain time forward so yield accrual is visible in a demo. */
function TimeTravel() {
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);

  async function warp(seconds: number) {
    setBusy(true);
    const rpc = (method: string, params: unknown[] = []) =>
      fetch(foundry.rpcUrls.default.http[0], {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
    await rpc("evm_increaseTime", [seconds]);
    await rpc("evm_mine");
    await queryClient.invalidateQueries();
    setBusy(false);
  }

  return (
    <div>
      <h3 className="text-sm font-medium">Time travel (local chain only)</h3>
      <p className="mt-0.5 text-xs text-muted">Fast-forward anvil&apos;s clock to watch NAV accrue.</p>
      <div className="mt-2 flex flex-wrap gap-2">
        {[
          ["+1 day", DAY],
          ["+30 days", 30 * DAY],
          ["+1 year", 365 * DAY],
        ].map(([label, s]) => (
          <Button key={label} variant="secondary" disabled={busy} onClick={() => warp(s as number)}>
            {label}
          </Button>
        ))}
      </div>
    </div>
  );
}

export function AdminPanel() {
  const p = usePosition();
  const chainId = useChainId();
  const isLocal = chainId === foundry.id;

  if (!p.isCompliance && !p.isYieldAdmin && !p.isPauser && !isLocal) return null;

  return (
    <Card title="Admin">
      <div className="grid gap-6 md:grid-cols-2">
        {p.isCompliance && <WhitelistAdmin />}
        {p.isYieldAdmin && <YieldAdmin />}
        {p.isPauser && <PauseAdmin />}
        {isLocal && <TimeTravel />}
      </div>
    </Card>
  );
}
