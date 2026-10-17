# Build and install the local Windows fork

Double-click the repository-root `使用.bat` file. The console remains open so build or install errors can be read.

The script:

1. Checks Node.js, npm and version metadata.
2. Uses Zig 0.16.0 from PATH, or downloads the official compiler into `.local-tools/` and verifies its pinned SHA-256. The download is only needed on the first run.
3. Builds the current repository source for the Node.js process architecture (Windows x64 or ARM64) using `ReleaseSafe`.
4. Creates one self-contained npm tarball containing that exact executable. It does not install platform dependencies from the npm registry.
5. Installs the tarball into an isolated directory, checks the executable hash and version, and runs `list --skip-api --json` with a separate, empty `CODEX_HOME`.
6. Uninstalls the current global npm `@loongphy/codex-auth` package, installs the local tarball, and checks the installed binary and generated command shim.

Build failure stops before uninstall. There is no old-version backup or automatic rollback. If installation fails after uninstall, correct the error and run the script again, or reinstall the published version with `npm install -g @loongphy/codex-auth`. Account data under the user's Codex home is not removed by this script.

Builds, packages and logs are kept in timestamped directories under `dist/local/`. `dist/local/latest-package.txt` points to the latest package that passed validation. The source version is preserved; the staged package's `codexAuthLocalBuild` metadata identifies its local source directory, build time and executable hash. Root publishing metadata and the upstream multi-platform staging workflow are unchanged.

Node.js, npm and curl must be available on PATH. Installation uses npm's existing global prefix; it does not change PATH or request elevation. If that prefix requires administrator access, npm reports a permissions error. The final output prints the installed command's full path; another installation earlier on PATH may shadow it.

## Validation without replacing the real global installation

Build, package and smoke-test only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/local/install.ps1 -PrepareOnly
```

Exercise the actual uninstall/install branch in a separate npm global prefix:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/local/install.ps1 -InstallPrefix "$PWD/dist/test-prefix"
```

The second command installs only into the supplied prefix; omitting `-InstallPrefix` targets the real global npm installation. Smoke tests never query remote account usage.

## Proxy settings

The installer does not hardcode a local proxy or change persistent proxy settings. Its download subprocess inherits the launching environment. To explicitly use a local HTTP proxy for the first compiler download, run from PowerShell:

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$env:HTTP_PROXY = 'http://127.0.0.1:7897'
& '.\使用.bat'
```

These variables affect that PowerShell process and its children. Double-clicking the batch file in Explorer does not inherit variables set in a separate PowerShell window. Independently of installer settings, this fork's compiled CLI hardcodes `http://127.0.0.1:7897` for API requests and disables environment bypass rules. No environment setup is needed for later CLI invocations, but the local proxy must be running. Rebuild and reinstall after changing the address in `src/api/http_curl.zig`. See [network review](network-review.md) for current runtime behavior and suggested improvements.
