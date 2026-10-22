"use client";

import { useSyncExternalStore } from "react";
import { useChainId, useConnection, useSwitchChain } from "wagmi";
import { deployments } from "@/deployments";
import { useDeployment } from "@/lib/hooks";
import { Activity } from "./Activity";
import { AdminPanel } from "./AdminPanel";
import { ConnectButton } from "./ConnectButton";
import { FundStats } from "./FundStats";
import { Position } from "./Position";
import { Trade } from "./Trade";
import { Button, Card } from "./ui";

// Wallet state only exists in the browser; render wallet-dependent UI after hydration.
const useMounted = () =>
  useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );

export function Dashboard() {
  const mounted = useMounted();
  const deployment = useDeployment();
  const chainId = useChainId();
  const { isConnected } = useConnection();
  const { chains, switchChain } = useSwitchChain();
  const supported = chains.filter((c) => deployments[c.id]);

  return (
    <div className="mx-auto w-full max-w-5xl px-4 py-8 sm:px-6">
      <header className="mb-8 flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">sgTBILL</h1>
          <p className="text-sm text-muted">Tokenized T-bill fund · permissioned · NAV-priced</p>
        </div>
        {mounted && <ConnectButton />}
      </header>

      {mounted && !deployment ? (
        <Card>
          <p className="text-sm">No sgTBILL deployment on this network (chain {chainId}).</p>
          <div className="mt-3 flex flex-wrap gap-2">
            {supported.map((c) => (
              <Button key={c.id} onClick={() => switchChain({ chainId: c.id })}>
                Switch to {c.name}
              </Button>
            ))}
          </div>
        </Card>
      ) : (
        <div className="grid gap-5">
          {mounted && <FundStats />}
          {mounted && isConnected ? (
            <>
              <div className="grid gap-5 md:grid-cols-2">
                <Position />
                <Trade />
              </div>
              <AdminPanel />
            </>
          ) : (
            mounted && (
              <Card>
                <p className="text-sm text-muted">Connect a wallet to deposit, redeem and see your position.</p>
              </Card>
            )
          )}
          {mounted && <Activity />}
        </div>
      )}

      <footer className="mt-10 text-xs text-muted">
        Educational demo on testnet. mUSDC is play money with an open faucet; yield is simulated by the vault minting
        mUSDC. Not a real security, not investment advice.
      </footer>
    </div>
  );
}
