# Timeout investigation (2026-10-17)

## Reproduction

The Windows machine uses curl 8.21.0 with Schannel and the local HTTP proxy at `127.0.0.1:7897`. Six distinct stored token/account pairs were tested against the usage endpoint with the same user agent and headers as the CLI. Credentials were supplied through stdin; only anonymous account labels, transport timings and status codes were recorded. No account was switched and no token was refreshed.

| Probe | Concurrent requests | Result |
| --- | --- | --- |
| Original 5-second transfer budget | 5 | 6/6 timed out with curl exit 28, at approximately 5.0 seconds |
| 20-second transfer budget | 5 | 6/6 returned HTTP 200; individual requests took 3.04–5.01 seconds |
| 20-second budget, revocation checks temporarily disabled for diagnosis | 5 | 6/6 returned HTTP 200; one still took 6.59 seconds, including 6.07 seconds to complete TLS |

In the successful normal-validation batch, connecting to the local proxy took about 0.5 milliseconds. Five HTTPS handshakes completed at about 4.22 seconds; response arrival brought total times close to the original 5-second cutoff. Timeout samples had a successful proxy CONNECT response but had not completed TLS.

Alternating unauthenticated single-request probes with and without revocation checks also reproduced a 4.98-second TLS handshake and 5.28-second total time with revocation checks disabled. The expected unauthenticated HTTP response was 401. This shows the delay can occur without parallel requests or account authentication, and skipping revocation checks does not reliably remove it.

## Finding and change

The confirmed failure mechanism is variable delay during HTTPS establishment after the local proxy accepts CONNECT, combined with an overly short total transfer deadline. This was reproduced directly in curl outside Zig, so these failures are not caused solely by the CLI's process watchdog or result formatting. All six authenticated requests succeeded with a larger budget, providing no evidence of invalid accounts in this sample.

Local timings cannot distinguish the proxy's outbound connection, the selected relay, the network path and the remote TLS peer. They do not prove one particular proxy node or remote server is at fault. No permanent certificate-check bypass was added.

The local proxy service log also contains earlier ChatGPT routing failures at 09:16 on the same day: outbound relay TCP connection timeouts and `context deadline exceeded`. These are historical supporting evidence of relay connectivity problems, not time-correlated proof of the 11:22–11:26 probes.

The transfer budget is now 20 seconds and the child-process watchdog is 22 seconds. Batch budget calculations use the same updated numeric request budget. Concurrency remains five, no retries were added, and certificate validation remains enabled. This accommodates the observed delays; it does not guarantee a response when the upstream path stalls for longer than 20 seconds. Existing callers with an overall deadline still bound the complete command.

## Validation and remaining failure

Two rebuilt CLI runs completed with no `TimedOut` or `RequestFailed`; the JSON run confirmed all six accounts had successful usage refreshes. A later run had no `TimedOut` but did show `RequestFailed`. A follow-up direct curl batch returned five HTTP 200 responses and one exit 35 with `schannel: failed to receive handshake, SSL/TLS connection failed` at 7.45 seconds. This is a separate transport failure that increasing the timeout cannot fix. The proxy/relay path still needs attention; the deadline change is not a claim of complete network reliability.

The four targeted HTTP, usage, account and identity test suites passed 24 tests and skipped one platform-specific symlink test. The ReleaseSafe npm tarball passed isolated packaging and local-only CLI smoke validation. The real global npm installation was not replaced during this investigation; rebuild/install through `使用.bat` to activate the changed deadlines there.

Timing-field meanings and the total-transfer scope of `--max-time` are documented in the [curl manual](https://curl.se/docs/manpage.html).
