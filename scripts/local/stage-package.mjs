import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function stageLocalPackage({ source, binary, destination, arch }) {
  if (!["x64", "arm64"].includes(arch)) throw new Error("Unsupported Windows architecture.");
  source = path.resolve(source);
  binary = path.resolve(binary);
  destination = path.resolve(destination);
  if (fs.existsSync(destination)) throw new Error("Package staging directory already exists.");
  const upstream = JSON.parse(fs.readFileSync(path.join(source, "package.json"), "utf8"));
  if (upstream.name !== "@loongphy/codex-auth") throw new Error("Unexpected package name.");
  const bytes = fs.readFileSync(binary);
  if (bytes.length < 64 || bytes.toString("ascii", 0, 2) !== "MZ") {
    throw new Error("The compiled Windows executable is invalid.");
  }
  fs.mkdirSync(path.join(destination, "bin/native"), { recursive: true });
  fs.copyFileSync(binary, path.join(destination, "bin/native/codex-auth.exe"));
  fs.copyFileSync(path.join(repo, "scripts/local/launcher.cjs"), path.join(destination, "bin/codex-auth.cjs"));
  for (const name of ["README.md", "LICENSE"]) {
    const filename = path.join(source, name);
    if (fs.existsSync(filename)) fs.copyFileSync(filename, path.join(destination, name));
  }
  // Deliberately omit upstream scripts and optionalDependencies. A local tgz
  // must contain the exact compiled binary, even when offline or unpublished.
  const manifest = {
    name: upstream.name,
    version: upstream.version,
    description: upstream.description,
    license: upstream.license,
    private: true,
    bin: { "codex-auth": "bin/codex-auth.cjs" },
    os: ["win32"],
    cpu: [arch],
    files: ["bin/", "LICENSE", "README.md"],
    codexAuthLocalBuild: {
      builtAt: new Date().toISOString(),
      source,
      binarySha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    },
  };
  fs.writeFileSync(path.join(destination, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
  return manifest;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source, binary, destination, arch] = process.argv.slice(2);
  if (!source || !binary || !destination || !arch) {
    throw new Error("Usage: stage-package.mjs SOURCE BINARY DESTINATION ARCH");
  }
  stageLocalPackage({ source, binary, destination, arch });
  console.log(`Staged self-contained local package: ${destination}`);
}
