#!/usr/bin/env node
// M0 spike test double — NOT part of the product path.
//
// A minimal ACP (Agent Client Protocol) stdio agent used only to prove the
// MoNexus transport loop when no real ACP agent can be installed. It speaks
// newline-delimited JSON-RPC 2.0 over stdio:
//   initialize -> session/new -> session/prompt
// and streams a few `session/update` notifications before the prompt
// response. If the prompt text contains "permission" it also sends one
// `session/request_permission` request.
//
// Kept in JavaScript on purpose: test-only, never linked into monexus-host.

import readline from "node:readline";

const SESSION_ID = "mock-session-1";
const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

let promptCount = 0;

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
    send({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: 1,
        agentCapabilities: { loadSession: false },
        agentInfo: { name: "mock-acp-agent", version: "0.0.1" },
        authMethods: [],
      },
    });
  } else if (method === "session/new") {
    send({ jsonrpc: "2.0", id, result: { sessionId: SESSION_ID } });
  } else if (method === "session/prompt") {
    promptCount += 1;
    const text = (params?.prompt ?? [])
      .map((block) => block?.text ?? "")
      .join(" ");
    const chunks = ["MOCK:", " hello", " from", " ACP", " #" + promptCount];
    for (const chunk of chunks) {
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: SESSION_ID,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: chunk },
          },
        },
      });
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    if (text.includes("permission")) {
      send({
        jsonrpc: "2.0",
        id: "perm-" + promptCount,
        method: "session/request_permission",
        params: {
          sessionId: SESSION_ID,
          toolCall: {
            toolCallId: "tool-" + promptCount,
            title: "mock tool call",
            kind: "other",
          },
          options: [
            { optionId: "allow_once", name: "Allow", kind: "allow_once" },
            { optionId: "reject_once", name: "Reject", kind: "reject_once" },
          ],
        },
      });
    }
    send({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } });
  } else if (method === "session/cancel") {
    // No long-running work to cancel in the mock.
  } else if (method === undefined && id !== undefined) {
    // A response from the client (e.g. the permission answer); nothing to do.
  } else if (id !== undefined) {
    send({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: "mock: unsupported method " + method },
    });
  }
}
