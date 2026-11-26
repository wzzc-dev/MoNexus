#!/usr/bin/env node
// JSON-RPC client for the paired-runtime acceptance harness.
//
// `monexus-host rpc` derives the idempotency key from a fresh request id, so it
// cannot replay the same client_request_id. These helpers let the harness pin
// both ids, which is what "the same client_request_id executes once" needs.
//
// Usage:
//   node tests/runtime/rpc_client.mjs call <state-dir> <id> <method> <params-json>
//   node tests/runtime/rpc_client.mjs fill <state-dir> <count> [prefix]
//
// `call` prints the raw JSON-RPC response and exits 0 for a result, 1 for an
// error, 2 for a transport failure. `fill` sends <count> host.status calls with
// distinct ids and exits 0; it is used to force the host's bounded response
// cache to clear before a replay test. The prefix keeps repeated fills from
// reusing ids (and therefore cache keys).

import { readFileSync } from "node:fs";

const USAGE =
  "usage: rpc_client.mjs call <state-dir> <id> <method> <params-json>\n" +
  "       rpc_client.mjs fill <state-dir> <count>";

function readHost(stateDir) {
  const text = readFileSync(`${stateDir}/host.json`, "utf8");
  const info = JSON.parse(text);
  if (!info.ws_url || !info.token) {
    throw new Error("host.json has no ws_url/token");
  }
  return info;
}

function connect(info) {
  return new WebSocket(info.ws_url, {
    headers: { Authorization: `Bearer ${info.token}` },
  });
}

function once(ws, id, method, params) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("timeout"));
    }, 60000);
    const onError = (event) => {
      cleanup();
      reject(new Error(`websocket error: ${event.message ?? "unknown"}`));
    };
    const cleanup = () => {
      clearTimeout(timer);
      ws.removeEventListener("message", onMessage);
      ws.removeEventListener("error", onError);
    };
    const onMessage = (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (message.id !== id) {
        return;
      }
      cleanup();
      resolve(message);
    };
    ws.addEventListener("message", onMessage);
    ws.addEventListener("error", onError);
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

async function run() {
  const [mode, stateDir, a, b, c] = process.argv.slice(2);
  if (!mode || !stateDir) {
    console.error(USAGE);
    process.exit(2);
  }
  const info = readHost(stateDir);
  const ws = connect(info);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", (event) => {
      reject(new Error(`websocket error: ${event.message ?? "unknown"}`));
    }, { once: true });
  });
  try {
    if (mode === "call") {
      const id = a;
      const method = b;
      const params = JSON.parse(c ?? "{}");
      if (!id || !method) {
        console.error(USAGE);
        process.exit(2);
      }
      const response = await once(ws, id, method, params);
      console.log(JSON.stringify(response));
      process.exit(response.error ? 1 : 0);
    }
    if (mode === "fill") {
      const count = Number.parseInt(a ?? "", 10);
      const prefix = b ?? `fill-${process.pid}`;
      if (!Number.isFinite(count) || count < 0) {
        console.error(USAGE);
        process.exit(2);
      }
      for (let i = 0; i < count; i += 1) {
        const id = `${prefix}-${i}`;
        await once(ws, id, "host.status", { client_request_id: id });
      }
      process.exit(0);
    }
    console.error(USAGE);
    process.exit(2);
  } finally {
    ws.close();
  }
}

run().catch((error) => {
  console.error(String(error.message ?? error));
  process.exit(2);
});
