import { OpenFeature } from "@openfeature/server-sdk";
import { FlagdProvider } from "@openfeature/flagd-provider";

const tenant = process.env.TENANT || "unknown";
const host = process.env.FLAGD_HOST || "localhost";
const port = parseInt(process.env.FLAGD_PORT || "8013", 10);
const workers = parseInt(process.env.WORKERS || "10", 10);
const reportIntervalMs = parseInt(process.env.REPORT_INTERVAL_MS || "5000", 10);
const yieldEvery = parseInt(process.env.YIELD_EVERY || "100", 10);
const cache = process.env.CACHE || "lru";
const resolverType = process.env.RESOLVER_TYPE || "rpc";
const flagCount = parseInt(process.env.FLAG_COUNT || "0", 10);
const explicitFlags = (process.env.EXPLICIT_FLAGS || "new-checkout-flow").split(",");

const provider = new FlagdProvider({ host, port, cache, resolverType });
await OpenFeature.setProviderAndWait(provider);
const client = OpenFeature.getClient();

let total = 0;
let errors = 0;
let lastReportTotal = 0;
let lastReportTime = Date.now();
let latencies = [];

function flagKey(workerId, i) {
  if (flagCount > 0) {
    return `bulk-flag-${(workerId * 1000 + i) % flagCount}`;
  }
  return explicitFlags[i % explicitFlags.length];
}

async function worker(id) {
  let i = 0;
  while (true) {
    const start = process.hrtime.bigint();
    try {
      const ctx = { targetingKey: `user-${id}-${i}`, userId: `user-${i % 1000}` };
      await client.getBooleanValue(flagKey(id, i), false, ctx);
      const ns = Number(process.hrtime.bigint() - start);
      latencies.push(ns / 1e6);
      total++;
    } catch (err) {
      errors++;
    }
    i++;
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
  const mem = process.memoryUsage();
  const heapMB = (mem.heapUsed / 1024 / 1024).toFixed(1);
  const rssMB = (mem.rss / 1024 / 1024).toFixed(1);
  console.log(
    `[${tenant}] resolver=${resolverType} cache=${cache} flags=${flagCount || explicitFlags.length} workers=${workers} total=${total} errors=${errors} rate=${rate}/s p50=${p50}ms p99=${p99}ms heap=${heapMB}MB rss=${rssMB}MB`,
  );
  lastReportTotal = total;
  lastReportTime = now;
  latencies = [];
  setTimeout(report, reportIntervalMs);
}

console.log(`[${tenant}] loader started, ${workers} workers, resolver=${resolverType} cache=${cache} flagCount=${flagCount} flagd=${host}:${port}`);
setTimeout(report, reportIntervalMs);
for (let i = 0; i < workers; i++) worker(i);
