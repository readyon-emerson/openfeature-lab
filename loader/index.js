import { OpenFeature } from "@openfeature/server-sdk";
import { FlagdProvider } from "@openfeature/flagd-provider";

const tenant = process.env.TENANT || "unknown";
const host = process.env.FLAGD_HOST || "localhost";
const port = parseInt(process.env.FLAGD_PORT || "8013", 10);
const workers = parseInt(process.env.WORKERS || "10", 10);
const reportIntervalMs = parseInt(process.env.REPORT_INTERVAL_MS || "5000", 10);
const yieldEvery = parseInt(process.env.YIELD_EVERY || "100", 10);

await OpenFeature.setProviderAndWait(new FlagdProvider({ host, port }));
const client = OpenFeature.getClient();

let total = 0;
let errors = 0;
let lastReportTotal = 0;
let lastReportTime = Date.now();
let latencies = [];

async function worker(id) {
  let i = 0;
  while (true) {
    const start = process.hrtime.bigint();
    try {
      const ctx = { targetingKey: `user-${id}-${i}`, userId: "user-1" };
      await client.getBooleanValue("new-checkout-flow", false, ctx);
      const ns = Number(process.hrtime.bigint() - start);
      latencies.push(ns / 1e6);
      total++;
    } catch (err) {
      errors++;
    }
    i++;
    // Yield to the event loop periodically. Without this, tight async loops
    // starve the macrotask queue and setTimeout reports never fire.
    if (i % yieldEvery === 0) await new Promise(setImmediate);
  }
}

function report() {
  const now = Date.now();
  const elapsedS = (now - lastReportTime) / 1000;
  const rate = ((total - lastReportTotal) / elapsedS).toFixed(0);
  const sorted = latencies.slice().sort((a, b) => a - b);
  const p50 = sorted.length ? sorted[Math.floor(sorted.length * 0.5)].toFixed(2) : "-";
  const p99 = sorted.length ? sorted[Math.floor(sorted.length * 0.99)].toFixed(2) : "-";
  console.log(
    `[${tenant}] loader workers=${workers} total=${total} errors=${errors} rate=${rate}/s p50=${p50}ms p99=${p99}ms`,
  );
  lastReportTotal = total;
  lastReportTime = now;
  latencies = [];
  setTimeout(report, reportIntervalMs);
}

console.log(`[${tenant}] loader started, ${workers} workers, flagd=${host}:${port}`);
setTimeout(report, reportIntervalMs);
for (let i = 0; i < workers; i++) worker(i);
