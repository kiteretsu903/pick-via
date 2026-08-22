# Browser Compatibility Evidence — 2026-08-21

## Localhost receiver harness

Status: **PASS for the receiver harness only.** Browser routing E2E has not run.

The receiver binds an ephemeral port on the exact IPv4 loopback address
`127.0.0.1`. Any other configured bind address is rejected before server
creation. Tokens are generated in memory with `secrets.token_urlsafe(24)`, are
one-shot, and are never persisted.

The CLI accepts counts only; it does not accept a routed URL. Its newline-delimited
JSON protocol is:

- readiness: `{"port": <ephemeral integer>, "tokens": [<opaque token>, ...]}`
- receipt: `{"token": <opaque token>, "receipt_time": <number>, "remote_address": "127.0.0.1"}`

Each successful request must have an exact raw target consisting only of one
registered token. It receives an empty 204 response and consumes that token.
Unknown targets, duplicates, and path or query variants all receive the same
empty 404 response and do not create receipts. Malformed or unsupported HTTP
requests receive generic empty error responses that do not reflect request data.
The configured receipt count is enforced atomically, including during concurrent
requests.

Privacy constraints verified by the harness:

- only token, receipt time, and loopback remote address enter a receipt;
- request paths, query strings, and headers are neither recorded nor emitted;
- default HTTP request logging is disabled;
- tokens and receipts remain process memory only;
- stdout contains only readiness and explicitly requested receipt records;
- stderr is empty during valid operation;
- invalid target-like arguments are rejected without being reflected to output;
- the receiver shuts down after the requested receipt count.

## Harness evidence

- `python3 scripts/browser-e2e/test_localhost_probe.py -v`: 15 tests ran, all OK.
- Live subprocess proof from a unique temporary working directory: one path/query
  variant returned 404, two independent registered tokens returned 204, exactly
  two minimal receipts were emitted, stdout/stderr passed the forbidden-data
  scan, the process exited with status 0, and the temporary directory was removed.

## Future browser routing matrix

| Browser edition or family | Launch evidence | Exact token receipt | Result |
| --- | --- | --- | --- |

No browser was launched for this harness task. All browser E2E rows remain
pending and must be added only after browser-specific routing proof is run.
