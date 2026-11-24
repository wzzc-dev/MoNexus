#!/usr/bin/env node
// M4 test double — NOT part of the product path.
//
// Line-oriented stdout adapter used to prove the documented fallback: the
// host treats raw stdout lines as transcript text and finalizes the session
// on EOF. It ignores stdin (the host may still write a prompt line) and exits
// after a few lines.

const lines = [
  "STDOUT-MOCK line 1",
  "STDOUT-MOCK line 2",
  "STDOUT-MOCK line 3",
];

process.stdin.resume();
process.stdin.on("data", () => {});

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

for (const line of lines) {
  process.stdout.write(line + "\n");
  await delay(60);
}
process.exit(0);
