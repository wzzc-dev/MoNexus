#!/usr/bin/env node
// M4 test double — NOT part of the product path.
//
// Minimal ACP (Agent Client Protocol) stdio agent used by
// scripts/agent_smoke.sh to exercise the host/provider loop without a real
// adapter: initialize -> session/new (or session/load) -> session/prompt.
//
// Behaviour:
//   * streams a few session/update agent_message_chunk notifications;
//   * echoes markers when the injected MoNexus context is present;
//   * if the prompt contains "permission", sends session/request_permission
//     and waits for the client's answer before finishing the turn;
//   * MOCK_ACP_FAIL=auth makes initialize fail with an auth-looking error;
//   * MOCK_ACP_FAIL=boom makes initialize fail with a generic error;
//   * MOCK_ACP_LOAD=0 advertises loadSession=false.
//
// Opt-in flags used by scripts/agent_ssh_smoke.sh (default behaviour is
// unchanged, so the existing smokes see the same bytes):
//   * --stderr writes MOCK-STDERR-READY at startup and
//     MOCK-CANCEL-RECEIVED on session/cancel to stderr only;
//   * --stderr-flood writes enough stderr lines to exceed the host's 2 KB
//     diagnostic window, ending with MOCK-STDERR-FLOOD-END;
//   * --stderr-key writes a fake multi-line private key block to stderr;
//   * --cwd streams a `CWD=<process.cwd()>` chunk in the first prompt;
//   * --hang keeps the first prompt in flight forever (no ACP response),
//     writes its pid to --pid-file and exits 3 on SIGTERM/SIGINT — used to
//     prove `lost` (kill local ssh) and `interrupted` (kill this process);
//   * --exit-after-turn exits 0 shortly after a normal prompt response — used
//     to prove a clean turn followed by EOF is still `exited`.
//   * --m1a-demo runs the M1a bootstrap demo only on the first prompt: it
//     reads AGENTS.md and one file under docs/, appends M1A-DEMO-EDIT to
//     --m1a-file (default notes.txt) once, runs --m1a-check (default
//     `sh -c 'test -f AGENTS.md && echo ok'`) and reports the cwd and markers.
//     This is opt-in so the existing smokes see the same bytes as before.
//
// Kept in JavaScript on purpose: test-only, never linked into monexus-host.

import fs from "node:fs";
import readline from "node:readline";
import { spawnSync } from "node:child_process";

const failMode = process.env.MOCK_ACP_FAIL || "";
const advertiseLoad = process.env.MOCK_ACP_LOAD !== "0";
const sessionId = process.env.MOCK_ACP_SESSION_ID || "mock-session-1";
const flags = new Set(process.argv.slice(2));
const stderrEnabled = flags.has("--stderr");
const floodEnabled = flags.has("--stderr-flood");
const keyEnabled = flags.has("--stderr-key");
const cwdEnabled = flags.has("--cwd");
const hangEnabled = flags.has("--hang");
const exitAfterTurn = flags.has("--exit-after-turn");
const m1aDemoEnabled = flags.has("--m1a-demo");

let pidFile = "";
let m1aFile = "notes.txt";
let m1aCheck = "sh -c 'test -f AGENTS.md && echo ok'";
for (let i = 0; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === "--pid-file" && i + 1 < process.argv.length) {
    pidFile = process.argv[i + 1];
  } else if (arg.startsWith("--pid-file=")) {
    pidFile = arg.slice("--pid-file=".length);
  } else if (arg === "--m1a-file" && i + 1 < process.argv.length) {
    m1aFile = process.argv[i + 1];
  } else if (arg.startsWith("--m1a-file=")) {
    m1aFile = arg.slice("--m1a-file=".length);
  } else if (arg === "--m1a-check" && i + 1 < process.argv.length) {
    m1aCheck = process.argv[i + 1];
  } else if (arg.startsWith("--m1a-check=")) {
    m1aCheck = arg.slice("--m1a-check=".length);
  }
}

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stderrLine = (text) => {
  if (stderrEnabled) process.stderr.write(text + "\n");
};

stderrLine("MOCK-STDERR-READY cwd=" + process.cwd());
// Credential-looking value used by the SSH smoke to prove the host redacts
// stderr before it reaches the log or the session record.
stderrLine("MOCK-AUTH api_key=VALUE-987654321");

if (hangEnabled) {
  // The smoke kills this process to simulate a remote agent exiting mid-turn.
  // Exit with a normal (non-255) status so the local ssh client reports it as
  // the remote program's exit, not as a transport failure.
  const exitOnSignal = () => process.exit(3);
  process.on("SIGTERM", exitOnSignal);
  process.on("SIGINT", exitOnSignal);
}
if (floodEnabled) {
  for (let i = 0; i < 240; i += 1) {
    stderrLine("MOCK-FLOOD-" + String(i).padStart(3, "0") + " " + "x".repeat(48));
  }
  stderrLine("MOCK-STDERR-FLOOD-END");
}
if (keyEnabled) {
  stderrLine("-----BEGIN OPENSSH PRIVATE KEY-----");
  stderrLine("FAKE-KEY-BODY-0123456789");
  stderrLine("-----END OPENSSH PRIVATE KEY-----");
}

const pendingReplies = new Map();
let promptCount = 0;
let permissionSeq = 0;

async function sendChunk(text) {
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text },
      },
    },
  });
  await delay(10);
}

async function sendThought(text) {
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text },
      },
    },
  });
  await delay(10);
}

async function requestPermission(text) {
  const id = "perm-" + ++permissionSeq;
  const answer = new Promise((resolve) => pendingReplies.set(id, resolve));
  send({
    jsonrpc: "2.0",
    id,
    method: "session/request_permission",
    params: {
      sessionId,
      toolCall: {
        toolCallId: "tool-" + permissionSeq,
        title: "mock tool call " + permissionSeq,
        kind: "other",
      },
      options: [
        { optionId: "allow_once", name: "Allow once", kind: "allow_once" },
        { optionId: "reject_once", name: "Reject", kind: "reject_once" },
      ],
    },
  });
  const reply = await answer;
  const outcome = reply?.result?.outcome ?? { outcome: "cancelled" };
  if (outcome.outcome === "selected") {
    await sendChunk(" PERMISSION selected:" + (outcome.optionId ?? "?"));
  } else {
    await sendChunk(" PERMISSION " + (outcome.outcome ?? "cancelled"));
  }
  return outcome;
}

async function m1aRead(path) {
  const text = fs.readFileSync(path, "utf8");
  return Buffer.byteLength(text, "utf8");
}

async function runM1aDemo() {
  try {
    const agentsBytes = await m1aRead("AGENTS.md");
    await sendChunk(" M1A-AGENTS-READ bytes=" + agentsBytes);
    const docsEntries = fs
      .readdirSync("docs", { withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => entry.name)
      .sort();
    if (docsEntries.length === 0) {
      throw new Error("docs/ has no readable file");
    }
    const docPath = "docs/" + docsEntries[0];
    const docBytes = await m1aRead(docPath);
    await sendChunk(" M1A-DOCS-READ=" + docPath + " bytes=" + docBytes);
    const marker = "M1A-DEMO-EDIT\n";
    const current = fs.readFileSync(m1aFile, "utf8");
    if (!current.includes(marker)) {
      const separator = current.endsWith("\n") ? "" : "\n";
      fs.appendFileSync(m1aFile, separator + marker);
    }
    await sendChunk(" M1A-EDIT=" + m1aFile);
    const check = spawnSync("sh", ["-c", m1aCheck], { encoding: "utf8" });
    if (check.error || check.status !== 0) {
      throw new Error(
        "validation failed status=" +
          check.status +
          " stderr=" +
          String(check.stderr ?? check.error ?? "").trim(),
      );
    }
    await sendChunk(" M1A-VALIDATE: " + String(check.stdout).trim());
    await sendChunk(" M1A-CWD=" + process.cwd());
  } catch (error) {
    await sendChunk(" M1A-ERROR: " + String(error.message ?? error));
  }
}

async function handlePrompt(id, params) {
  promptCount += 1;
  const text = (params?.prompt ?? []).map((block) => block?.text ?? "").join(" ");
  await sendChunk("MOCK#" + promptCount + " start");
  if (cwdEnabled) {
    await sendChunk(
      " CWD=" + process.cwd() + " TTY=" + (process.stdout.isTTY ? "yes" : "no"),
    );
  }
  if (m1aDemoEnabled && promptCount === 1) {
    await runM1aDemo();
  }
  if (hangEnabled) {
    // In-flight turn: publish the pid for the smoke harness and never send the
    // ACP response. The turn ends only when the transport or this process is
    // killed.
    if (pidFile) fs.writeFileSync(pidFile, String(process.pid) + "\n");
    stderrLine("MOCK-HANG-READY pid=" + process.pid);
    await sendChunk(" HANG");
    await new Promise(() => {});
    return;
  }
  await sendThought("checking injected context");
  await sendChunk(" CTX");
  if (text.includes("[MoNexus agent context]")) await sendChunk(" BLOCK_SEEN");
  if (text.includes("AGENTS.md (read-only)")) await sendChunk(" AGENTS_SEEN");
  if (text.includes("SMOKE-MEMORY")) await sendChunk(" MEMORY_SEEN");
  if (text.includes("[MoNexus Chat continuation context]")) {
    await sendChunk(" RECOVERY_CONTEXT_SEEN");
    const start = text.indexOf("[MoNexus Chat continuation context]");
    const endMarker = "[/MoNexus Chat continuation context]";
    const end = text.indexOf(endMarker, start + 1);
    if (start >= 0 && end >= 0) {
      const block = text.slice(start, end + endMarker.length);
      await sendChunk(" M1A-HANDOFF-SEEN");
      await sendChunk(" M1A-HANDOFF-BYTES=" + Buffer.byteLength(block, "utf8"));
    }
  }
  if (text.includes("CHAT-SYSTEM-BOUNDARY")) {
    await sendChunk(" SYSTEM_CONTEXT_LEAK");
  }
  if (/permission/i.test(text)) {
    await requestPermission(text);
  } else {
    await sendChunk(" done");
  }
  send({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } });
  if (exitAfterTurn) {
    await delay(50);
    process.exit(0);
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

let queue = Promise.resolve();

for await (const line of rl) {
  if (!line.trim()) continue;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    continue;
  }
  const { id, method, params } = message;
  if (method === "initialize") {
    if (failMode === "auth") {
      send({
        jsonrpc: "2.0",
        id,
        error: { code: -32000, message: "Authentication required: run the agent login first" },
      });
    } else if (failMode === "boom") {
      send({
        jsonrpc: "2.0",
        id,
        error: { code: -32000, message: "mock initialize exploded" },
      });
    } else {
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: 1,
          agentCapabilities: { loadSession: advertiseLoad },
          agentInfo: { name: "mock-acp-agent", version: "0.4.0-test" },
          authMethods: [],
        },
      });
    }
  } else if (method === "session/new") {
    send({ jsonrpc: "2.0", id, result: { sessionId } });
  } else if (method === "session/load") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (method === "session/prompt") {
    queue = queue.then(() => handlePrompt(id, params));
  } else if (method === "session/cancel") {
    // No long-running work in the mock; with --stderr the reception itself is
    // the evidence that the notification crossed the transport.
    stderrLine("MOCK-CANCEL-RECEIVED session=" + (params?.sessionId ?? ""));
  } else if (method === undefined && id !== undefined) {
    const resolver = pendingReplies.get(id);
    if (resolver) {
      pendingReplies.delete(id);
      resolver(message);
    }
  } else if (id !== undefined) {
    send({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: "mock: unsupported method " + method },
    });
  }
}
