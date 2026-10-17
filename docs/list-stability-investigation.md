# List stability investigation (2026-10-17)

## Scope and installed build

The globally installed native executable matches the latest prepared local package (SHA-256 `48238cac45d876e06e51ec682a07e0a93f2dfc5a8255e2a8c05a09056ec8ac52`). It includes the fixed HTTP proxy `127.0.0.1:7897` and 20-second transfer budget. A version mismatch or a missing installation of the timeout change does not explain this reproduction.

This investigation did not change the installed executable, request concurrency, proxy selection or production source behavior. Real account credentials were read into memory for GET usage queries and passed to curl on stdin; transport reports use anonymous account labels. File-concurrency tests used isolated Codex homes and fabricated accounts, never copies of real credentials.

## Transport failure reproduced without Zig concurrency

Two six-account batches were run at each concurrency, interleaved as 5, 1, 2, 5, 2, 1. All used the same system curl, endpoint, proxy, certificate validation and 20-second deadline.

| Concurrent requests | Successful HTTP 200 | TLS failures | Timeouts | Batch durations |
| --- | --- | --- | --- | --- |
| 1 | 10/12 | 2/12 | 0 | 26.33 s, 24.75 s |
| 2 | 9/12 | 3/12 | 0 | 5.00 s, 5.52 s |
| 5 | 8/12 | 4/12 | 0 | 10.83 s, 2.06 s |

Failures were curl exit 35, `schannel: failed to receive handshake, SSL/TLS connection failed`. The local proxy accepted CONNECT (HTTP 200), but the target HTTPS handshake did not complete. These samples cannot establish that concurrency determines the failure rate: sequential requests also fail, the sample is small, and the upstream route varies over time.

A temporary curl executable wrapper, selected only through a child process's PATH, also captured the real curl exit and timings inside two installed CLI runs. Each CLI run reported five successful rows and one `RequestFailed`; each underlying batch had exactly five curl exit-0/HTTP-200 results and one curl exit-35 result. No successful curl result was observed being misclassified by the Zig wrapper in these probes. Credentials and response bodies were not written to the wrapper's diagnostic logs.

Additional controls did not eliminate the failure:

- Git's curl 8.15.0 (also Schannel) failed three of twelve requests in two paired follow-up batches; an earlier separate six-request batch had all succeeded. One successful batch is insufficient evidence of a curl-version fix.
- System curl forced to TLS 1.2 failed one of twelve requests.
- Python OpenSSL 3.0.16, connecting through the same explicit HTTP proxy, also reproduced `SSLEOFError: UNEXPECTED_EOF_WHILE_READING` during TLS establishment. Its five-worker batch succeeded five of six times; its sequential batch succeeded six of six times.

The live mihomo controller was queried read-only through its existing Windows pipe. The `ChatGPT` selector was set to `美国LA-优化-GPT`; observed ChatGPT connections used that chain. No selector was changed. Local observations locate the failure after acceptance by the local proxy and before completion of TLS; they do not prove whether the relay, intermediate network, or remote peer closed the connection. They also do not establish that another configured node would be reliable without testing it.

The production HTTP wrapper maps nonzero curl exits other than 28 to the generic `RequestFailed`, discarding the specific error. Increasing the deadline does not repair a connection that has already been closed during TLS.

## Separate cross-process registry collision

Multiple CLI processes can collide even with all network access removed:

- Simultaneous first-use `list --skip-api --json` calls in isolated fake-account homes reproduced `registry_error: AccessDenied`.
- Five concurrent processes against an already initialized fake-account home, with a local fake curl returning changing usage values, also reproduced `AccessDenied`. A separate cold batch reproduced `FileNotFound`.
- Thirty simultaneous-in-batches local-only calls against an initialized, unchanged registry all succeeded in this run. Thirty calls with constant fake API responses also all succeeded. Exercising changed usage values was necessary to reliably test the save path, rather than just unchanged cache reads.

A diagnostic copy of the source was compiled with error return traces; production sources were not instrumented. The copy passed `zig build run -- list` against an isolated dummy login. The captured warm-registry failure path was:

```text
workflows/list.zig: computeListState
workflows/usage.zig: persist refreshed usage
registry/storage_write.zig: saveRegistry
registry/storage_write.zig: writeRegistryFileReplace
rename registry.json to a temporary backup -> AccessDenied
```

The Windows replacement implementation moves the existing registry away and then renames a new file into place. Concurrent readers/writers can encounter sharing failures or a temporarily missing path. This is a real cross-process file-operation problem, distinct from curl exit 35. The experiments do not show that every production `list` failure is a registry collision.

## Recommended changes

1. Preserve curl exit code and a redacted transport error so TLS failure, timeout, HTTP rejection and local registry failure remain distinguishable. Add only bounded retries for selected transient transport errors, within an explicit overall budget; do not retry authentication failures as congestion or disable certificate validation.
2. Test the ChatGPT route with a different appropriate proxy node before attributing the failures to any particular relay. Lowering request concurrency may reduce bursts but is not a complete fix, as the sequential failures demonstrate.
3. Coordinate registry read/modify/write and account-import operations across CLI processes, including readers around the Windows replacement sequence. Keep network requests outside short file-operation critical sections; preserve newer active-account/alias data when merging refreshed usage. A write-only lock or a long global lock around interactive/live sessions is insufficient.

The next implementation should validate both classes independently: repeated real GET batches for transport behavior, and changing fake usage plus concurrent CLI commands for registry consistency. Neither disabling TLS checks nor merely raising the timeout addresses both failures.

References: [curl timing fields and exit codes](https://curl.se/docs/manpage.html), [mihomo controller proxy endpoints](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/proxies.go).
