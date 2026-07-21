# ocwd/ — AGENTS.md

## OVERVIEW

Daemon-specific code for `ocwd`, the Unix-socket supervisor that manages opencode and openchamber lifecycles.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `ocwd.v` | Forks via `daemonize` unless `--foreground`/`--no-daemon` is passed. Handles `--version`, `--help`, `--reload`, `--restart`, `--shutdown`. |
| `run_daemon` | `ocwd.v` | pidfile, socket bind, signal setup, `App.run()`. Parses `--cwd`, `--config`. |
| `App` | `ocwd.v` | Supervisor state: process slots, channels, listen fd, tick timer, conf path. |
| `App.run` | `ocwd.v` | `select` loop on `req_ch`, `death_ch`, and `tick_ch`. |
| `App.tick` | `ocwd.v` | Starts opencode; waits for port occupancy before starting openchamber. Checks SIGHUP reload flag. |
| `App.on_death` | `ocwd.v` | Back-off, respawn, and cascade stop of openchamber. |
| `App.cmd_reload` | `ocwd.v` | Re-reads `state.json` and configured env file, adjusts processes. |
| `App.cmd_version` | `ocwd.v` | Reports running and on-disk versions, detects mismatches. |
| `App.adopt_existing_proc` | `ocwd.v` | Adopts an already-running process on daemon startup or after self-exec. |
| `App.self_restart` | `ocwd.v` | Re-executes the on-disk binary on SIGUSR2 (from `--restart`), preserving supervised processes. |
| `spawn_proc` | `ocwd.v` | Creates `os.Process`, sets env/cwd/pgroup, spawns `log_pump`. |
| `restart_proc` | `ocwd.v` | Stops a process without clearing `have_proc`; the death event drives respawn. |
| `log_pump` | `ocwd.v` | Per-process goroutine draining stdout/stderr into a log file and emitting `DeathMsg`. |
| `log_msg` | `ocwd.v` | Writes to `daemon.log` and to stderr in foreground mode. |
| `find_pid_by_cmd` | `ocwd.v` | Scans `/proc` to find a process matching a command name. |
| `c_listen` | `ocwd.v` | AF_UNIX server socket bind/listen. |
| `handle_client` | `ocwd.v` | Reads one JSON line, routes to `handle_req`, writes one JSON line. |
| `handle_req` | `ocwd.v` | Command dispatcher for `status`, `start`, `stop`, `restart`, `logs`, `reload`, `version`, `shutdown`. |
| `port_free` | `ocwd.v` | TCP dial to decide if a process is listening. |
| `backoff_for` | `ocwd.v` | Back-off table: 1, 2, 4, 8, 16, 30 seconds. |
| `g_ocwd_pids` / `g_ocwd_listen` / `g_ocwd_reload` / `g_ocwd_foreground` | `globals.h` | C static globals for the signal handler and foreground detection. |

## ANTI-PATTERNS

- Do not set `have_proc = false` inside `restart_proc`. The `log_pump` death event is the single respawn trigger; clearing it early can spawn duplicate processes while the port is still releasing.
- Do not ignore the `pr.p.pid != msg.pid` guard in `on_death`. Stale death reports from a previous incarnation must be ignored.
- Do not break the opencode -> openchamber dependency. `openchamber` is only started once `opencode` is alive and `opencode_port` is occupied.
- Do not start `ocwd` under a shell that exits quickly. The daemon expects to be re-parented to init; use `ocwd` normally or `ocwd --foreground` / `ocwd --no-daemon` for foreground debugging.

## UNIQUE STYLES

- **Manual C globals:** `globals.h` stores `g_ocwd_pids[2]`, `g_ocwd_listen`, `g_ocwd_reload`, and `g_ocwd_foreground` because V's `module main` has no mutable module globals. The signal handler reads these directly.
- **Log pump per process:** every spawned process gets its own goroutine that drains stdout/stderr into a file and sends a `DeathMsg` on exit. This is the only source of restart events.
- **Process adoption on startup:** the daemon can adopt already-running `opencode` / `openchamber` processes, provided their `cmdline` contains the expected `--port` argument.
- **Port occupancy as health check:** `port_free` dials the TCP port (4096 for opencode, 4097 for openchamber) to decide whether a process is listening.
- **JSON line protocol:** clients send one JSON line and the daemon replies with one JSON line; the `logs` command is the only one that keeps the socket open for streaming.
- **Explicit back-off table:** `backoff_for` uses fixed intervals `1, 2, 4, 8, 16, 30` seconds instead of exponential calculation.
- **Foreground logging:** in foreground mode `stdout`/`stderr` stay on the terminal; `log_msg` also writes a copy to `/run/ocwd/daemon.log`. In background mode they are redirected to `daemon.log`.

## COMMANDS

```bash
# Build only the daemon (parent build.sh handles this)
v -prod ocwd/ -o /usr/local/bin/ocwd

# Run in background (normal)
ocwd

# Run in foreground for debugging
ocwd --foreground
# or
ocwd --no-daemon

# Use a custom environment file
ocwd --config /path/to/env.conf
ocwd --env-file /path/to/env.conf

# Reload a running daemon without restarting it
ocwd --reload

# Re-exec the running daemon with the on-disk binary (supervised processes preserved)
ocwd --restart

# Stop the running daemon completely (supervised processes included)
ocwd --shutdown

# Show daemon version/help
ocwd --version
ocwd --help

# Format and lint this directory
v fmt -w .
v vet .
```

## NOTES

- `ocwd/common.v` is a symlink to the shared protocol definitions in the root `common.v`.
- The daemon writes to `/run/ocwd`, which must exist and be writable by the user running `ocwd`.
- On first startup after 0.2.x, the daemon refuses to run beside a live legacy `ocd` process and copies `/run/ocd/state.json` when the new state file is absent.
- `openchamber` will never be started by `App.tick` if opencode is not healthy; restarting opencode automatically cascades to stopping openchamber first.
- Logs are written per-process to files under the configured log directory; the `logs` command streams the tail of those files over the Unix socket.
- `ocwd --config` and `ocwd --env-file` override the default `/etc/opencode-web.conf` path; `ocw reload` re-reads the configured file on a running daemon.
- `ocwd` can adopt already-running `opencode` / `openchamber` processes on startup, provided their `cmdline` contains the expected `--port` argument. The scan requires both the command path and the port to match, so unrelated processes with a similar name (e.g. an interactive `opencode` TUI client) are never adopted.
- `ocwd --restart` sends SIGUSR2 to the running daemon; on the next supervisor tick it validates the on-disk binary with `--version`, removes the socket and pidfile, then re-executes itself with the same arguments. The pidfile must be removed before `execve` or the new daemon detects its own pid and exits with "already running". After the exec, the new daemon adopts the supervised processes, so their pids keep running without interruption. The daemon keeps the **same pid** across the restart because `execve` replaces the process image in place; the pidfile is rewritten with the identical value.
