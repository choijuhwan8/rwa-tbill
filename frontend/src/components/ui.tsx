"use client";

import type { ButtonHTMLAttributes, ReactNode } from "react";
import { useChainId, useChains } from "wagmi";
import type { TxState } from "@/lib/hooks";

export function Card({ title, aside, children }: { title?: string; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="rounded-xl border border-border bg-surface p-5">
      {(title || aside) && (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title && <h2 className="text-sm font-semibold tracking-wide text-muted uppercase">{title}</h2>}
          {aside}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="text-xs text-muted">{label}</div>
      <div className="mt-1 truncate font-mono text-xl font-medium tabular-nums">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function Button({
  variant = "primary",
  className = "",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" }) {
  const styles =
    variant === "primary"
      ? "bg-accent text-accent-foreground hover:opacity-90"
      : "border border-border bg-surface hover:bg-background";
  return (
    <button
      {...props}
      className={`rounded-lg px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-40 ${styles} ${className}`}
    />
  );
}

export function Input(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className={`w-full min-w-0 rounded-lg border border-border bg-background px-3 py-2 font-mono text-sm outline-none focus:border-accent ${props.className ?? ""}`}
    />
  );
}

export function TxStatus({ state }: { state: TxState }) {
  const chainId = useChainId();
  const chain = useChains().find((c) => c.id === chainId);
  const explorer = chain?.blockExplorers?.default.url;

  if (state.status === "idle") return null;
  if (state.status === "error") return <p className="mt-3 text-sm break-words text-negative">{state.message}</p>;
  if (state.status === "success")
    return (
      <p className="mt-3 text-sm text-positive">
        {state.label} confirmed
        {explorer && (
          <>
            {" · "}
            <a className="underline" href={`${explorer}/tx/${state.hash}`} target="_blank" rel="noreferrer">
              view tx
            </a>
          </>
        )}
      </p>
    );
  return (
    <p className="mt-3 text-sm text-muted">
      {state.label}: {state.status === "pending" ? "confirm in your wallet…" : "waiting for confirmation…"}
    </p>
  );
}
