import { deployments } from "@/deployments";

// Vault event history for a live network, fetched server-side from the Etherscan v2 API.
//
// Why not just eth_getLogs from the browser? Free RPC tiers cap log queries hard (Alchemy
// free: 10 blocks; public nodes: ~1,000 blocks ≈ 3 hours). A month after deploy the vault's
// history spans ~216k blocks. Etherscan indexes logs and returns the whole range in one call.
// Running it here keeps ETHERSCAN_API_KEY out of the browser bundle.
//
// Only the known vault for a known chain is queryable, so this can't be used as an open
// proxy for the key.

export async function GET(request: Request) {
  const chainId = Number(new URL(request.url).searchParams.get("chainId"));
  const d = deployments[chainId];
  const apiKey = process.env.ETHERSCAN_API_KEY;
  if (!d || chainId === 31337) return Response.json({ error: "unsupported chain" }, { status: 400 });
  if (!apiKey) return Response.json({ error: "ETHERSCAN_API_KEY not configured" }, { status: 503 });

  const params = new URLSearchParams({
    chainid: String(chainId),
    module: "logs",
    action: "getLogs",
    address: d.vault,
    fromBlock: String(d.deployedAtBlock),
    toBlock: "latest",
    page: "1",
    offset: "1000", // oldest-first; plenty for a demo vault, the client keeps the newest
    apikey: apiKey,
  });

  try {
    const res = await fetch(`https://api.etherscan.io/v2/api?${params}`, { cache: "no-store" });
    const body = await res.json();
    // Etherscan reports "no logs yet" as status "0" with an empty result.
    const logs = Array.isArray(body.result) ? body.result : null;
    if (!logs) return Response.json({ error: body.message ?? "etherscan error" }, { status: 502 });
    return Response.json(
      { logs },
      // Let the CDN share one response across visitors for 10s, keeping well under
      // Etherscan's free rate limit however many graders have the page open.
      { headers: { "Cache-Control": "public, s-maxage=10, stale-while-revalidate=30" } },
    );
  } catch {
    return Response.json({ error: "etherscan unreachable" }, { status: 502 });
  }
}
