"use client";

import { useChainId, useConnect, useConnection, useDisconnect, useSwitchChain } from "wagmi";
import { foundry } from "wagmi/chains";
import { deployments } from "@/deployments";
import { shortAddr } from "@/lib/format";
import { Button } from "./ui";

export function ConnectButton() {
  const { address, isConnected } = useConnection();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { chains, switchChain } = useSwitchChain();
  const chainId = useChainId();

  const supported = chains.filter((c) => deployments[c.id]);

  if (!isConnected) {
    return (
      <div className="flex flex-col items-end gap-1">
        <div className="flex flex-wrap gap-2">
          {connectors.map((c) => (
            <Button
              key={c.uid}
              variant={c.type === "mock" ? "secondary" : "primary"}
              onClick={() => connect({ connector: c, chainId: c.type === "mock" ? foundry.id : undefined })}
              disabled={isPending}
            >
              {c.type === "mock" ? "Anvil dev account" : "Connect wallet"}
            </Button>
          ))}
        </div>
        {error && (
          <p className="text-xs text-negative">
            {error.message.includes("Provider not found") ? "No browser wallet found." : error.message}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <select
        aria-label="Network"
        value={chainId}
        onChange={(e) => switchChain({ chainId: Number(e.target.value) as (typeof chains)[number]["id"] })}
        className="rounded-lg border border-border bg-surface px-2 py-2 text-sm"
      >
        {supported.map((c) => (
          <option key={c.id} value={c.id}>
            {c.name}
          </option>
        ))}
        {!deployments[chainId] && <option value={chainId}>Unsupported network</option>}
      </select>
      <Button variant="secondary" onClick={() => disconnect()} title="Disconnect">
        <span className="font-mono">{shortAddr(address!)}</span>
      </Button>
    </div>
  );
}
