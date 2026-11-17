# Troubleshooting

Every error hit during development, what it means, and the fix.

## Error reference

| Error string | Meaning | Fix |
|---|---|---|
| `Access denied: checkprefs access denied` | Caller uid (peercred 999) ≠ daemon's expected operator/root view | Seed `OperatorUser="container"` in the `-config` file |
| `Access denied: profiles access denied` | Same peercred mismatch, on the profile store | Same as above |
| `Access denied: serve config denied` | Same mismatch, on `/localapi/v0/serve-config` (used by `tailscale serve`/`funnel`) | Same as above |
| `Access denied: login access denied` | Same mismatch, on login | `up` with a valid `--authkey` also works once operator matches |
| `no current Tailscale IPs; state: NeedsLogin` | Node not logged in yet | Run `tailscale up --authkey=...` |
| `failed to connect to local tailscaled ... connection refused` | Daemon died (reaped after exec session) | Re-run `keepalive.sh` |
| `unmarshaling known profiles: unexpected end of JSON input` | Corrupt/truncated seeded state file | Don't seed the state file; use the `-config` file |
| `cannot unmarshal string into Go struct field LoginProfile._profiles of type []uint8` | Seeded state used a JSON string instead of base64 `[]byte` | Use the `-config` file instead |
| `Tailscale is stopped` / `health(warnable=wantrunning-false)` | `WantRunning=false` | `tailscale up` |
| `tstun: error initializing tun dev stats polling ... no such device` | No `/dev/net/tun` (expected in sandbox) | Harmless with `--tun=userspace-networking` |
| `TPM: error opening: stat /dev/tpmrm0: no such file or directory` | No TPM device | Harmless — state is stored unencrypted |

## Diagnosis recipes

### Am I root? (trick question in PRoot)

```sh
id -u                                   # may say 0
cat /proc/self/status | grep '^Uid'     # the kernel truth, e.g. 999
```

If these disagree, you are in a PRoot-style sandbox and the peercred fix applies.

### Is the daemon alive and healthy?

```sh
ls -la /tmp/tailscaled.sock
tailscale --socket=/tmp/tailscaled.sock status
```

### What uid does the daemon think the caller is?

Watch the daemon log for lines like:

```
connection from userid <N>; is configured operator
connection from userid <N>; read-only
```

Match the operator uid to `<N>`.

### Is Funnel actually configured?

```sh
tailscale --socket=/tmp/tailscaled.sock funnel status
```

### Is the public URL reachable?

```sh
curl -s -w '\nHTTP:%{http_code}\n' https://<host>.<tailnet>.ts.net/health
```

- `200` with `{"ok":true,...}` → all good
- `403` on `/` → TLS + Funnel OK; the app is refusing an unauthenticated request (expected)
- `000` → DNS/TLS not ready yet; wait ~30s after first start (cert issuance)

## Gotchas

- **`pkill -f tailscaled` kills your own shell** if the pattern matches the command
  line that runs it. Kill exact PIDs:
  ```sh
  kill $(ps -eo pid,args | awk '/[t]ailscaled/ && /tscfg.sock/ {print $1}')
  ```
  (Note the `[t]` trick so the grep/awk command itself is not matched.)
- **Never seed `tailscaled.state`** — the `LoginProfile` JSON format is internal and
  version-specific. Use the `-config` file for `OperatorUser`.
- **`funnel --bg <port>`** exposes on public port `443` by default; use
  `--https=<port>` to choose another.
- First start can take ~30 s while the ACME cert is issued.
