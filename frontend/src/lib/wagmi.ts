import { createConfig, fallback, http, injected, mock } from "wagmi";
import { foundry, sepolia } from "wagmi/chains";
import { deployments } from "@/deployments";

// Sepolia first when it has a deployment, so a visitor without a wallet reads the live
// testnet fund; otherwise fall back to the local anvil chain.
const chains = deployments[sepolia.id] ? ([sepolia, foundry] as const) : ([foundry, sepolia] as const);

// anvil's default accounts (unlocked on the local node, so they need no key here).
// #0 deploys and holds every admin role; #1 plays a fresh, not-yet-whitelisted investor.
export const ANVIL_ADMIN = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const;
export const ANVIL_INVESTOR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const;

export const config = createConfig({
  chains,
  connectors: [
    injected(),
    // Dev-only "wallet" that forwards transactions to anvil, which signs for its unlocked
    // accounts. Lets you demo the full flow locally without MetaMask. Never in prod builds.
    ...(process.env.NODE_ENV === "development"
      ? [ANVIL_ADMIN, ANVIL_INVESTOR].map((a) => mock({ accounts: [a], features: { reconnect: true } }))
      : []),
  ],
  transports: {
    // Several endpoints in order: if one is down or rate-limiting, viem moves to the next,
    // so the dApp keeps working for weeks without anyone watching it. An optional private
    // endpoint (restrict its key to your domain, it is visible in the browser) goes first.
    [sepolia.id]: fallback([
      ...(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ? [http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL)] : []),
      http("https://ethereum-sepolia-rpc.publicnode.com"),
      http(), // viem's default (thirdweb)
    ]),
    [foundry.id]: http("http://127.0.0.1:8545"),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
