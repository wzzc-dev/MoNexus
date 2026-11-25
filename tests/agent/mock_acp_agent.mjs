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
//   * --cwd streams a `CWD=<process.cwd()>` chunk in the first prompt.
//
// Kept in JavaScript on purpose: test-only, never linked into monexus-host.

import readline from "node:readline";

const failMode = process.env.MOCK_ACP_FAIL || "";
const advertiseLoad = process.env.MOCK_ACP_LOAD !== "0";
const sessionId = process.env.MOCK_ACP_SESSION_ID || "mock-session-1";
const flags = new Set(process.argv.slice(2));
const stderrEnabled = flags.has("--stderr");
const cwdEnabled = flags.has("--cwd");

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stderrLine = (text) => {
  if (stderrEnabled) process.stderr.write(text + "\n");
};

stderrLine("MOCK-STDERR-READY cwd=" + process.cwd());
// Credential-looking value used by the SSH smoke to prove the host redacts
// stderr before it reaches the log or the session record.
stderrLine("MOCK-AUTH api_key=VALUE-987654321");

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

async function handlePrompt(id, params) {
  promptCount += 1;
  const text = (params?.prompt ?? []).map((block) => block?.text ?? "").join(" ");
  await sendChunk("MOCK#" + promptCount + " start");
  if (cwdEnabled) {
    await sendChunk(
      " CWD=" + process.cwd() + " TTY=" + (process.stdout.isTTY ? "yes" : "no"),
    );
  }
  await sendThought("checking injected context");
  await sendChunk(" CTX");
  if (text.includes("[MoNexus agent context]")) await sendChunk(" BLOCK_SEEN");
  if (text.includes("AGENTS.md (read-only)")) await sendChunk(" AGENTS_SEEN");
  if (text.includes("SMOKE-MEMORY")) await sendChunk(" MEMORY_SEEN");
  if (/permission/i.test(text)) {
    await requestPermission(text);
  } else {
    await sendChunk(" done");
  }
  send({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } });
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
