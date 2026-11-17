# OpenClaw Anywhere — Public HTTPS URL on a PRoot Sandbox via Tailscale Funnel

A complete, battle-tested guide to exposing a **local service (e.g. the OpenClaw gateway on port 18789)** to the public internet over a **stable HTTPS URL**, from inside a locked-down, non-systemd, PRoot-style container sandbox (Altare / Pterodactyl-style panel).

Result you get:

```
https://<host>.<tailnet>.ts.net/          ->  http://127.0.0.1:18789
```

Verified end-to-end: `GET /health` → `{"ok":true,"status":"live"}` with a **real Tailscale TLS certificate**, no public IP, no inbound port opening, no reverse proxy on the host.

---

## TL;DR

```sh
# 1. Put the helper scripts in place (see scripts/)
cp scripts/keepalive.sh scripts/config.json /workspace/ocanywhere/
chmod +x /workspace/ocanywhere/keepalive.sh

# 2. Provide your auth key (do NOT commit it)
export TS_AUTHKEY="tskey-auth-..."

# 3. Start it
sh /workspace/ocanywhere/keepalive.sh

# 4. Verify
curl -s -w '\nHTTP:%{http_code}\n' https://<host>.<tailnet>.ts.net/health
```

---

## The Problem

The sandbox:

- has **no `systemd`**, no `supervisord` (PID 1 is `tini --entrypoint.sh`)
- runs every process inside a **PRoot** user-space sandbox
- reaps background daemons when the controlling exec session ends

Naively running `tailscale up` or `tailscale funnel` fails with a wall of errors:

```
Access denied: checkprefs access denied
Access denied: profiles access denied
Access denied: serve config denied
Access denied: login access denied
```

This guide explains **why** and gives the exact configuration that makes Funnel work.

---

## Root Cause: the PRoot uid mismatch

Inside the sandbox, the process sees **two different uids**:

| Where the uid comes from | Value seen |
|---|---|
| `getuid()` (libc / Go runtime) | `0` (root) |
| `SO_PEERCRED` on the unix socket (kernel) | `999` (`container`) |

Tailscale's daemon authorizes every *write* operation (login, prefs, serve/funnel config) by reading the **socket peer credentials** (`SO_PEERCRED`) and comparing the caller's uid against the configured operator / root.

Because:

- the daemon believes it is root (`getuid() == 0`), so it needs no operator, and
- every caller arrives on the socket as **uid 999**,

…every privileged localapi call returns `Access denied`. This is why:

- `tailscale status` / `prefs` (read) work, but
- `tailscale set`, `up`, `funnel`, `login-interactive` fail.

> Diagnostics that revealed this:
> ```sh
> id -u                      # -> 0
> cat /proc/self/status | grep '^Uid'   # -> 999 999 999 999
> ```

---

## The Fix

### 1. Run your OWN tailscaled, with your own state dir

Do not rely on a host/container-provided daemon. Run a dedicated one:

```sh
/usr/sbin/tailscaled \
  --tun=userspace-networking \
  --statedir=/workspace/tailscale-state \
  --state=/workspace/tailscale-state/tailscaled.state \
  --config=/workspace/ocanywhere/config.json \
  --socket=/tmp/tailscaled.sock
```

- `--tun=userspace-networking` — no `/dev/net/tun`, no root capabilities needed.
- `--statedir` — node identity persists here, so you log in **once**.

### 2. THE MASTER KEY — seed `OperatorUser = "container"`

Create a **tailscaled config file** (not the state file!) with:

```json
{
  "Version": "alpha0",
  "Locked": false,
  "ServerURL": "",
  "OperatorUser": "container"
}
```

`container` is the name of uid `999` — the uid that arrives on the socket as the peer. Because the operator now **matches the peercred uid**, all privileged localapi calls are authorized.

- `"OperatorUser": "root"` → **denied** (peer is 999, root is 0 → mismatch)
- `"OperatorUser": "container"` → **allowed** (999 == 999) ✅

> Why not seed the `tailscaled.state` file?
> The profile store inside the state file is a base64-encoded `[]byte` containing an
> `ipn.LoginProfile` structure whose exact JSON shape is undocumented and version-specific
> (`_profiles`, `_current-profile`, `_default-profile` are all typed objects, not strings).
> Any wrong field fails with `json: cannot unmarshal ...`. The `-config` file is the
> supported, stable way to inject `OperatorUser`.

### 3. Log in the node

```sh
tailscale --socket=/tmp/tailscaled.sock up \
  --hostname=<your-host> \
  --authkey="tskey-auth-..."
```

Node identity is written into `--statedir`, so subsequent restarts do **not** need the auth key.

### 4. Enable Funnel

```sh
tailscale --socket=/tmp/tailscaled.sock funnel --bg 18789
```

Output:

```
Available on the internet:
https://<host>.<tailnet>.ts.net/
|-- proxy http://127.0.0.1:18789
Funnel started and running in the background.
```

### 5. Verify

```sh
curl -s -w '\nHTTP:%{http_code}\n' https://<host>.<tailnet>.ts.net/health
# {"ok":true,"status":"live"}
# HTTP:200
```

`/` returning `403` is **expected** — that's the gateway rejecting an unauthenticated
request, and it proves DNS + TLS + Funnel are all working.

---

## Persistence (the sandbox reaps daemons)

Background daemons do **not** survive the end of the controlling exec session. Options:

1. **On-demand** — keep a `keepalive.sh` (idempotent) and run it whenever the tunnel
   dies. Best when you don't want a permanent supervisor.
   ```sh
   sh /workspace/ocanywhere/keepalive.sh
   ```
2. **Periodic re-raise** — schedule `keepalive.sh` (e.g. every minute) via your
   gateway's own scheduler/automation. The script exits immediately if the daemon
   is already healthy, so it is cheap.

The `keepalive.sh` in `scripts/` is idempotent: it checks the socket + `tailscale status`
first and only starts the daemon when needed.

---

## Files in this repo

| File | Purpose |
|---|---|
| `scripts/keepalive.sh` | Idempotent start/re-raise for tailscaled + Funnel |
| `scripts/config.json` | tailscaled config seeding `OperatorUser=container` |
| `scripts/verify.sh` | Curl the public URL and print HTTP codes |
| `docs/TROUBLESHOOTING.md` | Every error string we hit and what it means |

---

## Security notes

- **Never commit** your Tailscale auth key. Pass it via env (`TS_AUTHKEY`) or the
  gateway's secret store.
- Funnel exposes the target port to the **public internet**. Put authentication in
  front of anything sensitive (the OpenClaw gateway already requires a token).
- The auth key used here is a **one-time / reusable** key scoped to your tailnet;
  revoke it in the Tailscale admin console if leaked.

---

## Credits / prior art

Built on the approach from
[`openclaw-anywhere`](https://github.com/panditvirchandra77-lgtm/openclaw-anywhere):
a dedicated `tailscaled` with its own `--statedir`, then Tailscale Funnel.
The PRoot uid/`OperatorUser` diagnosis is the piece this guide adds.
