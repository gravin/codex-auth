import assert from "node:assert/strict";
import fs from "node:fs";
import { spawnSync } from "node:child_process";

const [launcher, isolatedHome] = process.argv.slice(2);
fs.mkdirSync(isolatedHome, { recursive: true });
const child = spawnSync(process.execPath, [launcher, "list", "--skip-api", "--json"], {
  env: { ...process.env, CODEX_HOME: isolatedHome },
  encoding: "utf8",
  timeout: 15_000,
  windowsHide: true,
});
if (child.error) throw child.error;
assert.equal(child.status, 0, child.stderr);
const result = JSON.parse(child.stdout);
assert.equal(result.command, "list");
assert.equal(result.schema_version, 1);
assert.ok(Array.isArray(result.accounts));
assert.equal(result.accounts.length, 0, "Smoke test must not read real account data.");
console.log("Isolated CLI list --skip-api --json passed (no real account access).");
