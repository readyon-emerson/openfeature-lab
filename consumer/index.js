import { OpenFeature } from "@openfeature/server-sdk";
import { FlagdProvider } from "@openfeature/flagd-provider";

const tenant = process.env.TENANT || "unknown";
const host = process.env.FLAGD_HOST || "localhost";
const port = parseInt(process.env.FLAGD_PORT || "8013", 10);

await OpenFeature.setProviderAndWait(new FlagdProvider({ host, port }));
const client = OpenFeature.getClient();

console.log(`[${tenant}] consumer ready, flagd=${host}:${port}`);

async function tick() {
  const ctx = { targetingKey: "user-1", userId: "user-1" };
  const checkout = await client.getBooleanValue("new-checkout-flow", false, ctx);
  const banner = await client.getStringValue("experiment-banner", "fallback", ctx);
  console.log(`[${tenant}] new-checkout-flow=${checkout} experiment-banner="${banner}"`);
}

setInterval(tick, 5000);
tick();
