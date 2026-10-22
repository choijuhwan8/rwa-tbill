import { formatUnits } from "viem";

export const USDC_DECIMALS = 6;
export const SHARE_DECIMALS = 18;

function group(value: string, maxFraction: number) {
  const n = Number(value);
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: maxFraction });
}

/** 6-decimal USDC base units → "1,234.56" */
export const fmtUsdc = (v: bigint | undefined, maxFraction = 2) =>
  v === undefined ? "—" : group(formatUnits(v, USDC_DECIMALS), maxFraction);

/** 18-decimal sgTBILL base units → "1,234.5678" */
export const fmtShares = (v: bigint | undefined, maxFraction = 4) =>
  v === undefined ? "—" : group(formatUnits(v, SHARE_DECIMALS), maxFraction);

/** 18-decimal NAV (1e18 == 1.00) → "1.000137" — enough digits to watch yield tick up. */
export const fmtNav = (v: bigint | undefined) => (v === undefined ? "—" : Number(formatUnits(v, 18)).toFixed(6));

/** basis points → "5.00%" */
export const fmtBps = (v: bigint | undefined) => (v === undefined ? "—" : `${(Number(v) / 100).toFixed(2)}%`);

export const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
