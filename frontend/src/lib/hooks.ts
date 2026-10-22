"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { BaseError, keccak256, toHex, zeroAddress } from "viem";
import { useChainId, useConnection, usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { deployments } from "@/deployments";
import { mockUSDCAbi, tBillTokenAbi, vaultAbi, whitelistAbi } from "./abis";
import type { config } from "./wagmi";

export const COMPLIANCE_ROLE = keccak256(toHex("COMPLIANCE_ROLE"));
export const YIELD_ADMIN_ROLE = keccak256(toHex("YIELD_ADMIN_ROLE"));
export const PAUSER_ROLE = keccak256(toHex("PAUSER_ROLE"));

const PRECISION = 10n ** 18n;
const SCALE = 10n ** 12n; // USDC 6dp → share 18dp, mirrors Vault.SCALE

const REFRESH_MS = 4_000;

/** The deployment for the chain the app is currently reading from (undefined if none). */
export function useDeployment() {
  const chainId = useChainId();
  return deployments[chainId];
}

/** Fund-level state. Readable without a wallet. */
export function useFund() {
  const d = useDeployment();
  const vault = { address: d?.vault ?? zeroAddress, abi: vaultAbi } as const;

  const q = useReadContracts({
    allowFailure: false,
    contracts: [
      { ...vault, functionName: "totalAssets" },
      { address: d?.token ?? zeroAddress, abi: tBillTokenAbi, functionName: "totalSupply" },
      { ...vault, functionName: "navPerToken" },
      { ...vault, functionName: "pendingYield" },
      { ...vault, functionName: "annualYieldRateBps" },
      { ...vault, functionName: "lastAccrualTimestamp" },
      { ...vault, functionName: "paused" },
      { ...vault, functionName: "MAX_YIELD_BPS" },
    ],
    query: { enabled: !!d, refetchInterval: REFRESH_MS },
  });

  const [totalAssets, totalSupply, nav, pendingYield, rateBps, lastAccrual, paused, maxRateBps] = q.data ?? [];

  // navPerToken() only reflects *settled* yield. Adding pendingYield gives the NAV a
  // redeemer would actually get if they transacted in the latest block.
  const liveNav =
    totalAssets !== undefined && totalSupply !== undefined && pendingYield !== undefined
      ? totalSupply === 0n
        ? PRECISION
        : ((totalAssets + pendingYield) * SCALE * PRECISION) / totalSupply
      : undefined;

  return { ...q, totalAssets, totalSupply, nav, liveNav, pendingYield, rateBps, lastAccrual, paused, maxRateBps };
}

/** Connected-wallet state. */
export function usePosition() {
  const d = useDeployment();
  const { address } = useConnection();
  const account = address ?? zeroAddress;

  const q = useReadContracts({
    allowFailure: false,
    contracts: [
      { address: d?.usdc ?? zeroAddress, abi: mockUSDCAbi, functionName: "balanceOf", args: [account] },
      { address: d?.token ?? zeroAddress, abi: tBillTokenAbi, functionName: "balanceOf", args: [account] },
      {
        address: d?.usdc ?? zeroAddress,
        abi: mockUSDCAbi,
        functionName: "allowance",
        args: [account, d?.vault ?? zeroAddress],
      },
      { address: d?.whitelist ?? zeroAddress, abi: whitelistAbi, functionName: "isWhitelisted", args: [account] },
      {
        address: d?.whitelist ?? zeroAddress,
        abi: whitelistAbi,
        functionName: "hasRole",
        args: [COMPLIANCE_ROLE, account],
      },
      { address: d?.vault ?? zeroAddress, abi: vaultAbi, functionName: "hasRole", args: [YIELD_ADMIN_ROLE, account] },
      { address: d?.vault ?? zeroAddress, abi: vaultAbi, functionName: "hasRole", args: [PAUSER_ROLE, account] },
    ],
    query: { enabled: !!d && !!address, refetchInterval: REFRESH_MS },
  });

  const [usdcBalance, shareBalance, allowance, isWhitelisted, isCompliance, isYieldAdmin, isPauser] = q.data ?? [];
  return { ...q, address, usdcBalance, shareBalance, allowance, isWhitelisted, isCompliance, isYieldAdmin, isPauser };
}

type Write = ReturnType<typeof useWriteContract<typeof config>>["writeContractAsync"];
/** One transaction. `send` receives wagmi's writeContractAsync so each call stays fully typed. */
export type TxStep = { label: string; send: (write: Write) => Promise<`0x${string}`> };

export type TxState =
  | { status: "idle" }
  | { status: "pending" | "confirming"; label: string }
  | { status: "success"; label: string; hash: `0x${string}` }
  | { status: "error"; message: string };

/**
 * Sends one or more transactions in order (e.g. approve → deposit), waiting for each
 * receipt before the next, then refreshes every on-chain read.
 */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const { address } = useConnection();
  const client = usePublicClient();
  const queryClient = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  // Dry-run every write first: a revert surfaces as the decoded reason ("zero deposit",
  // NotWhitelisted(...), AccessControl...) instead of a mined, gas-burning failed tx.
  const simulateThenWrite = (async (request: Parameters<Write>[0]) => {
    await client!.simulateContract({ ...request, account: address } as Parameters<typeof client.simulateContract>[0]);
    return writeContractAsync(request);
  }) as Write;

  async function run(steps: TxStep[]) {
    try {
      let hash: `0x${string}` = "0x";
      let label = "";
      for (const step of steps) {
        label = step.label;
        setState({ status: "pending", label });
        hash = await step.send(simulateThenWrite);
        setState({ status: "confirming", label });
        const receipt = await client!.waitForTransactionReceipt({ hash, pollingInterval: 1_000 });
        if (receipt.status !== "success") throw new Error(`${label} reverted`);
      }
      setState({ status: "success", label, hash });
      await queryClient.invalidateQueries();
      return true;
    } catch (e) {
      const message = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
      setState({ status: "error", message });
      return false;
    }
  }

  const busy = state.status === "pending" || state.status === "confirming";
  return { run, state, busy, reset: () => setState({ status: "idle" }) };
}
