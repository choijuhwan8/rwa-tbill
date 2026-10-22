"use client";

import { useQuery } from "@tanstack/react-query";
import { useChainId, useChains, usePublicClient } from "wagmi";
import { vaultAbi } from "@/lib/abis";
import { fmtNav, fmtShares, fmtUsdc, shortAddr } from "@/lib/format";
import { useDeployment } from "@/lib/hooks";
import { Card } from "./ui";

export function Activity() {
  const d = useDeployment()!;
  const client = usePublicClient();
  const chainId = useChainId();
  const explorer = useChains().find((c) => c.id === chainId)?.blockExplorers?.default.url;

  const q = useQuery({
    queryKey: ["activity", chainId, d.vault],
    queryFn: async () => {
      const logs = await client!.getContractEvents({
        address: d.vault,
        abi: vaultAbi,
        fromBlock: BigInt(d.deployedAtBlock),
      });
      return logs
        .filter((l) => ["Deposited", "Redeemed", "YieldAccrued"].includes(l.eventName))
        .reverse()
        .slice(0, 12);
    },
    enabled: !!client,
    refetchInterval: 12_000,
  });

  return (
    <Card title="Recent activity">
      {q.isLoading && <p className="text-sm text-muted">Loading…</p>}
      {q.isError && <p className="text-sm text-muted">Activity unavailable from this RPC.</p>}
      {q.data?.length === 0 && <p className="text-sm text-muted">No activity yet.</p>}
      <ul className="divide-y divide-border">
        {q.data?.map((l) => {
          let text = "";
          if (l.eventName === "Deposited") {
            const a = l.args as { user: string; usdcIn: bigint; sharesOut: bigint };
            text = `${shortAddr(a.user)} deposited $${fmtUsdc(a.usdcIn)} → ${fmtShares(a.sharesOut, 2)} sgTBILL`;
          } else if (l.eventName === "Redeemed") {
            const a = l.args as { user: string; sharesIn: bigint; usdcOut: bigint };
            text = `${shortAddr(a.user)} redeemed ${fmtShares(a.sharesIn, 2)} sgTBILL → $${fmtUsdc(a.usdcOut)}`;
          } else {
            const a = l.args as { usdcAdded: bigint; newNavPerToken: bigint };
            text = `Yield +$${fmtUsdc(a.usdcAdded, 6)} · NAV ${fmtNav(a.newNavPerToken)}`;
          }
          return (
            <li
              key={`${l.transactionHash}-${l.logIndex}`}
              className="flex items-center justify-between gap-3 py-2.5 text-sm"
            >
              <span className="min-w-0 truncate">{text}</span>
              {explorer ? (
                <a
                  className="shrink-0 font-mono text-xs text-muted underline"
                  href={`${explorer}/tx/${l.transactionHash}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  #{l.blockNumber?.toString()}
                </a>
              ) : (
                <span className="shrink-0 font-mono text-xs text-muted">#{l.blockNumber?.toString()}</span>
              )}
            </li>
          );
        })}
      </ul>
    </Card>
  );
}
