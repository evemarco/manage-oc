# ocd/ — AGENTS.md

## OVERVIEW

Daemon-specific code for `ocd`, the Unix-socket supervisor that manages opencode and openchamber lifecycles.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `ocd.v:801` | Forks via `daemonize` unless `--foreground`/`--no-daemon` is passed. |
| `run_daemon` | `ocd.v:720` | pidfile, socket bind, signal setup, then `App.run()`. |
| `App` | `ocd.v:245` | Supervisor state: process slots, channels, listen fd, tick timer. |
| `App.run` | `ocd.v:698` | `select` loop on `req_ch`, `death_ch`, and `tick_ch`. |
| `App.tick` | `ocd.v:365` | Starts opencode; waits for port occupancy before starting openchamber. |
| `App.on_death` | `ocd.v:387` | Back-off, respawn, and cascade stop of openchamber. |
| `spawn_proc` | `ocd.v:319` | Creates `os.Process`, sets env/cwd/pgroup, spawns `log_pump`. |
| `restart_proc` | `ocd.v:347` | Stops a process without clearing `have_proc`; the death event drives respawn. |
| `log_pump` | `ocd.v:547` | Per-process goroutine draining stdout/stderr into a log file and emitting `DeathMsg`. |
| `c_listen` | `ocd.v:177` | AF_UNIX server socket bind/listen. |
| `handle_client` | `ocd.v:642` | Reads one JSON line, routes to `handle_req`, writes one JSON line. |
| `handle_req` | `ocd.v:512` | Command dispatcher for `status`, `start`, `stop`, `restart`, `logs`, `shutdown`. |
| `port_free` | `ocd.v:131` | TCP dial to decide if a process is listening. |
| `backoff_for` | `ocd.v:272` | Back-off table: 1, 2, 4, 8, 16, 30 seconds. |
| `g_ocd_pids` / `g_ocd_listen` | `globals.h` | C static globals for the SIGTERM/SIGINT handler. |

## ANTI-PATTERNS

- Do not set `have_proc = false` inside `restart_proc`. The `log_pump` death event is the single respawn trigger; clearing it early can spawn duplicate processes while the port is still releasing.
- Do not ignore the `pr.p.pid != msg.pid` guard in `on_death`. Stale death reports from a previous incarnation must be ignored.
- Do not break the opencode -> openchamber dependency. `openchamber` is only started once `opencode` is alive and `opencode_port` is occupied.
- Do not start `ocd` under a shell that exits quickly. The daemon expects to be re-parented to init; use `ocd` normally or `ocd --foreground` / `ocd --no-daemon` for foreground debugging.

## UNIQUE STYLES

- **Manual C globals:** `globals.h` stores `g_ocd_pids[2]` and `g_ocd_listen` because V's `module main` has no mutable module globals. The signal handler reads these directly.
- **Log pump per process:** every spawned process gets its own goroutine that drains stdout/stderr into a file and sends a `DeathMsg` on exit. This is the only source of restart events.
- **Port occupancy as health check:** `port_free` dials the TCP port (4096 for opencode, 4097 for openchamber) to decide whether a process is listening.
- **JSON line protocol:** clients send one JSON line and the daemon replies with one JSON line; the `logs` command is the only one that keeps the socket open for streaming.
- **Explicit back-off table:** `backoff_for` uses fixed intervals `1, 2, 4, 8, 16, 30` seconds instead of exponential calculation.

## COMMANDS

```bash
# Build only the daemon (parent build.sh handles this)
v -prod ocd/ -o /usr/local/bin/ocd

# Run in background (normal)
ocd

# Run in foreground for debugging
ocd --foreground
# or
ocd --no-daemon

# Format and lint this directory
v fmt -w .
v vet .
```

## NOTES

- `ocd/common.v` is a symlink to the shared protocol definitions in the root `common.v`.
- The daemon writes to `/run/ocd`, which must exist and be writable by the user running `ocd`.
- `openchamber` will never be started by `App.tick` if opencode is not healthy; restarting opencode automatically cascades to stopping openchamber first.
- Logs are written per-process to files under the configured log directory; the `logs` command streams the tail of those files over the Unix socket.
