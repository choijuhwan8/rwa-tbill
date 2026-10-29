"use client";

import { parseUnits } from "viem";
import { useBalance, useChainId } from "wagmi";
import { sepolia } from "wagmi/chains";
import { mockUSDCAbi, whitelistAbi } from "@/lib/abis";
import { fmtShares, fmtUsdc } from "@/lib/format";
import { useDeployment, useFund, usePosition, useTx } from "@/lib/hooks";
import { Button, Card, Stat, TxStatus } from "./ui";

const FAUCET_AMOUNT = parseUnits("1000", 6);
// Below this a wallet can't reliably pay for a few transactions even on cheap Sepolia gas.
const LOW_GAS = parseUnits("0.0005", 18);
const SEPOLIA_FAUCET = "https://cloud.google.com/application/web3/faucet/ethereum/sepolia";

export function Position() {
  const d = useDeployment()!;
  const p = usePosition();
  const f = useFund();
  const tx = useTx();
  const kyc = useTx();
  const chainId = useChainId();
  const eth = useBalance({ address: p.address, query: { refetchInterval: 15_000 } });
  const lowGas = chainId === sepolia.id && eth.data !== undefined && eth.data.value < LOW_GAS;

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

      {lowGas && (
        <p className="mt-4 rounded-lg bg-warning/15 px-3 py-2 text-sm text-warning">
          This wallet needs a little Sepolia ETH for gas.{" "}
          <a className="underline" href={SEPOLIA_FAUCET} target="_blank" rel="noreferrer">
            Get free Sepolia ETH
          </a>{" "}
          (Google account, about a minute).
        </p>
      )}

      {p.isWhitelisted === false && (
        <div className="mt-4 rounded-lg border border-border p-3 text-sm">
          <p className="text-muted">
            sgTBILL is a permissioned token: only whitelisted (KYC&apos;d) addresses can hold it.
          </p>
          {p.isRevoked ? (
            <p className="mt-2 text-negative">This address was removed by the compliance officer.</p>
          ) : f.selfService ? (
            <>
              <Button
                className="mt-3"
                disabled={kyc.busy}
                onClick={() =>
                  kyc.run([
                    {
                      label: "Identity verification",
                      send: (w) => w({ address: d.whitelist, abi: whitelistAbi, functionName: "selfWhitelist" }),
                    },
                  ])
                }
              >
                Verify identity (demo KYC)
              </Button>
              <p className="mt-2 text-xs text-muted">
                Testnet stand-in for a KYC provider: one transaction adds your address to the on-chain whitelist.
              </p>
              <TxStatus state={kyc.state} />
            </>
          ) : (
            <p className="mt-2 text-muted">
              Ask the compliance admin to whitelist <span className="font-mono">{p.address}</span>.
            </p>
          )}
        </div>
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
