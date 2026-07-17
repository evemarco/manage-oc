# ocd/ — AGENTS.md

## OVERVIEW

Daemon-specific code for `ocd`, the Unix-socket supervisor that manages opencode and openchamber lifecycles.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `ocd.v` | Forks via `daemonize` unless `--foreground`/`--no-daemon` is passed. Handles `--version`, `--help`, `--reload`, `--shutdown`. |
| `run_daemon` | `ocd.v` | pidfile, socket bind, signal setup, `App.run()`. Parses `--cwd`, `--config`. |
| `App` | `ocd.v` | Supervisor state: process slots, channels, listen fd, tick timer, conf path. |
| `App.run` | `ocd.v` | `select` loop on `req_ch`, `death_ch`, and `tick_ch`. |
| `App.tick` | `ocd.v` | Starts opencode; waits for port occupancy before starting openchamber. Checks SIGHUP reload flag. |
| `App.on_death` | `ocd.v` | Back-off, respawn, and cascade stop of openchamber. |
| `App.cmd_reload` | `ocd.v` | Re-reads `state.json` and configured env file, adjusts processes. |
| `App.cmd_version` | `ocd.v` | Reports running and on-disk versions, detects mismatches. |
| `App.adopt_existing_proc` | `ocd.v` | Adopts an already-running process on daemon startup. |
| `spawn_proc` | `ocd.v` | Creates `os.Process`, sets env/cwd/pgroup, spawns `log_pump`. |
| `restart_proc` | `ocd.v` | Stops a process without clearing `have_proc`; the death event drives respawn. |
| `log_pump` | `ocd.v` | Per-process goroutine draining stdout/stderr into a log file and emitting `DeathMsg`. |
| `log_msg` | `ocd.v` | Writes to `daemon.log` and to stderr in foreground mode. |
| `find_pid_by_cmd` | `ocd.v` | Scans `/proc` to find a process matching a command name. |
| `c_listen` | `ocd.v` | AF_UNIX server socket bind/listen. |
| `handle_client` | `ocd.v` | Reads one JSON line, routes to `handle_req`, writes one JSON line. |
| `handle_req` | `ocd.v` | Command dispatcher for `status`, `start`, `stop`, `restart`, `logs`, `reload`, `version`, `shutdown`. |
| `port_free` | `ocd.v` | TCP dial to decide if a process is listening. |
| `backoff_for` | `ocd.v` | Back-off table: 1, 2, 4, 8, 16, 30 seconds. |
| `g_ocd_pids` / `g_ocd_listen` / `g_ocd_reload` / `g_ocd_foreground` | `globals.h` | C static globals for the signal handler and foreground detection. |

## ANTI-PATTERNS

- Do not set `have_proc = false` inside `restart_proc`. The `log_pump` death event is the single respawn trigger; clearing it early can spawn duplicate processes while the port is still releasing.
- Do not ignore the `pr.p.pid != msg.pid` guard in `on_death`. Stale death reports from a previous incarnation must be ignored.
- Do not break the opencode -> openchamber dependency. `openchamber` is only started once `opencode` is alive and `opencode_port` is occupied.
- Do not start `ocd` under a shell that exits quickly. The daemon expects to be re-parented to init; use `ocd` normally or `ocd --foreground` / `ocd --no-daemon` for foreground debugging.

## UNIQUE STYLES

- **Manual C globals:** `globals.h` stores `g_ocd_pids[2]`, `g_ocd_listen`, `g_ocd_reload`, and `g_ocd_foreground` because V's `module main` has no mutable module globals. The signal handler reads these directly.
- **Log pump per process:** every spawned process gets its own goroutine that drains stdout/stderr into a file and sends a `DeathMsg` on exit. This is the only source of restart events.
- **Process adoption on startup:** the daemon can adopt already-running `opencode` / `openchamber` processes, provided their `cmdline` contains the expected `--port` argument.
- **Port occupancy as health check:** `port_free` dials the TCP port (4096 for opencode, 4097 for openchamber) to decide whether a process is listening.
- **JSON line protocol:** clients send one JSON line and the daemon replies with one JSON line; the `logs` command is the only one that keeps the socket open for streaming.
- **Explicit back-off table:** `backoff_for` uses fixed intervals `1, 2, 4, 8, 16, 30` seconds instead of exponential calculation.
- **Foreground logging:** in foreground mode `stdout`/`stderr` stay on the terminal; `log_msg` also writes a copy to `/run/ocd/daemon.log`. In background mode they are redirected to `daemon.log`.

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

# Use a custom environment file
ocd --config /path/to/env.conf
ocd --env-file /path/to/env.conf

# Reload a running daemon without restarting it
ocd --reload

# Stop the running daemon completely (supervised processes included)
ocd --shutdown

# Show daemon version/help
ocd --version
ocd --help

# Format and lint this directory
v fmt -w .
v vet .
```

## NOTES

- `ocd/common.v` is a symlink to the shared protocol definitions in the root `common.v`.
- The daemon writes to `/run/ocd`, which must exist and be writable by the user running `ocd`.
- `openchamber` will never be started by `App.tick` if opencode is not healthy; restarting opencode automatically cascades to stopping openchamber first.
- Logs are written per-process to files under the configured log directory; the `logs` command streams the tail of those files over the Unix socket.
- `ocd --config` and `ocd --env-file` override the default `/etc/opencode-web.conf` path; `oc reload` re-reads the configured file on a running daemon.
- `ocd` can adopt already-running `opencode` / `openchamber` processes on startup, provided their `cmdline` contains the expected `--port` argument.
