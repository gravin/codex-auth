#!/usr/bin/env node
// Self-contained local package: never resolve a binary from the npm registry.
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

const manifest = require("../package.json");
if (process.platform !== "win32" || !manifest.cpu.includes(process.arch)) {
  console.error(`This local build requires Windows ${manifest.cpu.join("/")}.`);
  process.exit(1);
}
const executable = path.join(__dirname, "native", "codex-auth.exe");
if (!fs.existsSync(executable)) {
  console.error("The local codex-auth binary is missing. Run the local installer again.");
  process.exit(1);
}
const child = spawnSync(executable, process.argv.slice(2), { stdio: "inherit" });
if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}
if (child.signal) process.kill(process.pid, child.signal);
else process.exit(child.status ?? 1);
