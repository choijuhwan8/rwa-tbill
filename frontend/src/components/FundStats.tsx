"use client";

import { fmtBps, fmtNav, fmtShares, fmtUsdc } from "@/lib/format";
import { useFund } from "@/lib/hooks";
import { Card, Stat } from "./ui";

export function FundStats() {
  const f = useFund();
  const unsettled = f.liveNav !== undefined && f.nav !== undefined ? f.liveNav - f.nav : undefined;

  return (
    <Card title="Fund" aside={<span className="text-xs text-muted">refreshes every 4s</span>}>
      <div className="grid grid-cols-2 gap-5 sm:grid-cols-4">
        <Stat
          label="NAV per sgTBILL"
          value={`$${fmtNav(f.liveNav)}`}
          sub={unsettled && unsettled > 0n ? `settled ${fmtNav(f.nav)} + accruing` : "fully settled"}
        />
        <Stat label="Target yield (APY)" value={fmtBps(f.rateBps)} sub="simple, ACT/365" />
        <Stat
          label="Total assets"
          value={`$${fmtUsdc(f.totalAssets)}`}
          sub={f.pendingYield ? `+ $${fmtUsdc(f.pendingYield, 6)} unsettled` : "mUSDC held by vault"}
        />
        <Stat label="Shares outstanding" value={fmtShares(f.totalSupply, 2)} sub="sgTBILL" />
      </div>
      {f.paused && (
        <p className="mt-4 rounded-lg bg-warning/15 px-3 py-2 text-sm text-warning">
          Deposits and redemptions are paused by the fund operator. Yield keeps accruing.
        </p>
      )}
      {f.isError && <p className="mt-4 text-sm text-negative">Could not read the vault: {f.error?.message}</p>}
    </Card>
  );
}
