# Network review and proposed improvements

This review describes the current source and recommended changes. Network behavior is not changed by the local build/install helper.

## Current behavior

- `src/api/http_executable.zig` resolves an external `curl` through PATH.
- `src/api/http_curl.zig` launches a separate curl process per HTTP request. It sends the bearer token and account header through curl configuration on stdin, avoiding credential-bearing command-line arguments.
- The curl command begins with `--disable`, which suppresses the default curl configuration file. It still inherits environment variables.
- `src/api/http_types.zig` fixes the transfer limit at 5 seconds and the child-process capture limit at 7 seconds. The transfer limit covers the entire request, including connection establishment and TLS.
- There is no explicit connection-timeout setting or automatic retry in this request path.
- `src/workflows/usage.zig` allows five foreground usage requests concurrently. Token/account pairs are already deduplicated by `src/api/usage.zig`; do not add redundant deduplication or assume one request per email, since different workspaces have different usage.
- A nonzero curl exit other than 28 becomes `RequestFailed`; exit 28 or the process watchdog becomes `TimedOut`. The concrete transport error and captured stderr are not returned in structured command output.
- `list --active` limits usage refresh to the active account and skips account metadata refresh. `list --skip-api` performs no remote API requests.
- Workspace names are already refreshed conditionally (missing names in an eligible grouped scope), rather than unconditionally for every account on every list. Failed lookups can be retried on a later list.
- Numeric/direct `switch <query>` resolves locally without the API refresh used by the interactive picker. Do not add redundant usage refresh to the direct switch path.

## Priorities

### 1. Configurable time budgets and actionable diagnostics

Use a single options object for total timeout, connection timeout, retry count and process watchdog. A practical initial profile is a 20-second transfer budget, a connection limit no greater than that budget, one transient-error retry and concurrency 3, all configurable. These are starting values to benchmark, not universal network guarantees.

Derive the process watchdog from the complete attempt and backoff budget. Changing `--max-time` while leaving the watchdog at 7 seconds would still kill the request prematurely. Revisit batch watchdog calculations and external callers such as elevator's 120-second overall command timeout together. An overall deadline should prevent many accounts and retries from turning one foreground command into an unbounded wait.

Preserve curl exit code, a small redacted transport-error string and timing fields such as DNS/connect/TLS/total duration. Distinguish DNS failure, refused connection, TLS verification failure, timeout and HTTP authentication/authorization responses. Keep stdout as one JSON object; human diagnostics belong on stderr or in an explicitly versioned structured schema. Preserve existing schema fields so elevator's parser continues to work.

Retry only eligible GET queries on transient transport failures, 429 or selected 5xx responses, with capped backoff/jitter and `Retry-After` handling. Do not retry 401/403 or TLS certificate validation errors as if they were temporary congestion. Do not disable TLS verification to hide a proxy problem. Authentication renewal is a separate flow, and rotating refresh tokens need per-account serialization.

### 2. Responsive display and explicit freshness

For ordinary display, show cached rows promptly and refresh in the background or allow a short cache TTL (for example 15-30 seconds). Keep a force-refresh path for automation and account selection. Cached usage must retain its timestamp/source and must not be relabeled as a fresh successful response after a network error. Maintain `--active` and `--skip-api` as simple existing options.

Put a short failure cooldown on account-name lookups so missing metadata does not repeatedly delay foreground display. Avoid changing successful lookup behavior unnecessarily; names are already conditionally refreshed.

### 3. Transport reuse only after measurement

Keeping external curl initially is reasonable: it preserves the working TLS/proxy implementation and avoids a large rewrite. Separate curl processes do not share connection pools, so a long-lived libcurl transport or bounded curl multi-request process could later reduce process startup and repeated TLS handshakes. Measure it first; account headers, error attribution and per-request deadlines must remain isolated. Retain stdin-based credentials, and never write access/refresh tokens to debug logs or proxy URLs.

## Proxy behavior and recommendation

Today the program does not read Windows Internet Settings or PAC files. It inherits curl's environment-based proxy selection. `--disable` also means placing proxy settings in `_curlrc` or `.curlrc` will not fix this program. A TUN interface can separately intercept traffic at the network layer, even when no proxy environment variables are present.

For the existing binary, explicit process environment is the least ambiguous choice:

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$env:HTTP_PROXY = 'http://127.0.0.1:7897'
$env:NO_PROXY = 'localhost,127.0.0.1'
codex-auth list --json
```

Use the actual listening proxy port; `7897` is machine-specific and should not become a built-in default. `HTTPS_PROXY` can correctly point to an `http://` proxy because HTTPS target connections use CONNECT. For SOCKS with proxy-side DNS, curl supports `socks5h://...`.

For a future implementation, expose explicit modes:

- `inherit` (default): preserve curl's environment selection; transparent TUN routing remains the operating system's responsibility.
- `custom`: use one validated proxy URL supplied by a CLI option, a dedicated environment variable or saved configuration. Define precedence explicitly, for example CLI > `CODEX_AUTH_PROXY` > saved custom URL. Decide and document whether standard `NO_PROXY` bypasses remain active.
- `system`: opt-in Windows static system-proxy lookup when enabled. Disabled system settings, protocol-specific proxy lists and PAC are different cases; do not silently enable a saved disabled proxy or claim PAC support without implementing it.
- `direct`: explicitly suppress application-level proxy settings. This does not bypass a TUN interface or change system routing.

Do not silently change routes after an explicit proxy fails. Report the selected mode/source and redacted destination in a doctor/debug command; this is more predictable than probing common localhost ports and silently sending credentials through whichever service answers. Validate supported schemes and report an unavailable custom proxy clearly.

Setting proxy variables only inside `使用.bat` would affect installation, not future CLI invocations launched by elevator, the custody GUI or a new terminal. To cover all those callers, use inherited persistent environment (restart parent apps afterwards) or implement runtime configuration inside codex-auth itself.

## References

- [curl proxy environment variables](https://curl.se/libcurl/c/libcurl-env.html)
- [curl command options](https://curl.se/docs/manpage.html)
- [OpenAI account sessions and refresh-token handling](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
