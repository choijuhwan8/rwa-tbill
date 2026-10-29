"use client";

import { useQuery } from "@tanstack/react-query";
import { hexToBigInt, parseEventLogs, type Address, type Hex } from "viem";
import { useChainId, useChains, usePublicClient } from "wagmi";
import { foundry } from "wagmi/chains";
import { vaultAbi } from "@/lib/abis";
import { fmtNav, fmtShares, fmtUsdc, shortAddr } from "@/lib/format";
import { useDeployment } from "@/lib/hooks";
import { Card } from "./ui";

type Client = NonNullable<ReturnType<typeof usePublicClient>>;
type EtherscanLog = {
  address: Address;
  data: Hex;
  topics: [Hex, ...Hex[]];
  blockNumber: Hex;
  transactionHash: Hex;
  logIndex: Hex;
};

// Free RPC tiers cap eth_getLogs ranges (public nodes ~1,000 blocks), so the fallback
// pages backwards through recent history in chunks rather than asking for it all at once.
const CHUNK = 999n;
const FALLBACK_CHUNKS = 6; // ≈ 20 hours of Sepolia history

async function fetchVaultLogs(client: Client, chainId: number, vault: Address, fromBlock: bigint) {
  // Local anvil has no range limit.
  if (chainId === foundry.id) return client.getContractEvents({ address: vault, abi: vaultAbi, fromBlock });

  // Live network: full history via the server-side Etherscan route.
  try {
    const res = await fetch(`/api/activity?chainId=${chainId}`);
    if (res.ok) {
      const { logs } = (await res.json()) as { logs: EtherscanLog[] };
      return parseEventLogs({
        abi: vaultAbi,
        logs: logs.map((l) => ({
          ...l,
          blockNumber: hexToBigInt(l.blockNumber),
          logIndex: Number(l.logIndex),
          blockHash: null,
          transactionIndex: null,
          removed: false,
        })),
      });
    }
  } catch {
    // fall through to the RPC
  }

  // Fallback: recent history straight from the RPC, newest chunk first.
  const latest = await client.getBlockNumber();
  const out = [];
  for (let i = 0, to = latest; i < FALLBACK_CHUNKS && to >= fromBlock; i++, to -= CHUNK + 1n) {
    const from = to - CHUNK > fromBlock ? to - CHUNK : fromBlock;
    out.unshift(...(await client.getContractEvents({ address: vault, abi: vaultAbi, fromBlock: from, toBlock: to })));
  }
  return out;
}

export function Activity() {
  const d = useDeployment()!;
  const client = usePublicClient();
  const chainId = useChainId();
  const explorer = useChains().find((c) => c.id === chainId)?.blockExplorers?.default.url;

  const q = useQuery({
    queryKey: ["activity", chainId, d.vault],
    queryFn: async () => {
      const logs = await fetchVaultLogs(client!, chainId, d.vault, BigInt(d.deployedAtBlock));
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
      {q.isError && (
        <p className="text-sm text-muted">Activity is temporarily unavailable. Fund data above is unaffected.</p>
      )}
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
