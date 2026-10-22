import { createConfig, http, injected, mock } from "wagmi";
import { foundry, sepolia } from "wagmi/chains";
import { deployments } from "@/deployments";

// Sepolia first when it has a deployment, so a visitor without a wallet reads the live
// testnet fund; otherwise fall back to the local anvil chain.
const chains = deployments[sepolia.id] ? ([sepolia, foundry] as const) : ([foundry, sepolia] as const);

// anvil's first default account (unlocked on the local node, so it needs no key here).
const ANVIL_ACCOUNT_0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

export const config = createConfig({
  chains,
  connectors: [
    injected(),
    // Dev-only "wallet" that forwards transactions to anvil, which signs for its unlocked
    // accounts. Lets you demo the full flow locally without MetaMask. Never in prod builds.
    ...(process.env.NODE_ENV === "development"
      ? [mock({ accounts: [ANVIL_ACCOUNT_0], features: { reconnect: true } })]
      : []),
  ],
  transports: {
    // Public RPCs are rate-limited; set NEXT_PUBLIC_SEPOLIA_RPC_URL (Alchemy/Infura) for reliability.
    [sepolia.id]: http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL || undefined),
    [foundry.id]: http("http://127.0.0.1:8545"),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
