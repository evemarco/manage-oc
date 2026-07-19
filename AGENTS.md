# manage-oc — Project Knowledge Base

**Generated:** 2026-07-19
**Language:** V (vlang) 0.5.2
**Stack:** V + inline C Unix sockets + `os.Process` supervisor + JSON line protocol

## OVERVIEW

`manage-oc` is a small process supervisor for local `opencode` / `openchamber` instances.
It consists of a Unix-socket daemon (`ocwd`), a CLI client (`ocw`), and a tiny `procwd` helper.

## STRUCTURE

```
.
├── common.v           # shared socket/protocol definitions (symlinked from ocw/, ocwd/)
├── build.sh           # compiles ocwd, ocw & procwd to /usr/local/bin
├── ocw/
│   ├── AGENTS.md      # CLI client knowledge base
│   ├── common.v       # same as root common.v
│   └── ocw.v          # CLI client: status | cwd | start | stop | restart | reload | logs | version | shutdown | help
├── ocwd/
│   ├── AGENTS.md      # daemon knowledge base
│   ├── common.v       # same as root common.v
│   ├── globals.h      # C globals shared with SIGTERM/SIGINT handler
│   └── ocwd.v         # daemon + supervisor loop
└── procwd/
    └── procwd.v       # utility: print cwd of process by pid or name
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Build / install binaries | `build.sh` | builds `ocwd`, `ocw` and `procwd` into `/usr/local/bin` |
| Daemon supervisor logic | `ocwd/ocwd.v` | spawn, restart, backoff, logging, signal handling, process adoption, reload |
| CLI client commands | `ocw/ocw.v` | `main()` dispatch + `do_*` helpers (including version, reload) |
| Shared protocol structs | `common.v` / `ocw/common.v` / `ocwd/common.v` | `Command`, `StatusResp`, `AckResp`, socket helpers |
| C globals for signal handler | `ocwd/globals.h` | `g_ocwd_pids`, `g_ocwd_listen`, `g_ocwd_reload`, `g_ocwd_foreground` |
| Process cwd / pid lookup | `procwd/procwd.v` | reads `/proc/<pid>/cwd` and scans `/proc` for process names |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `main` | fn | `ocwd/ocwd.v` | forks via `daemonize` unless `--foreground`/`--no-daemon` |
| `run_daemon` | fn | `ocwd/ocwd.v` | pidfile, socket, signal setup, `App.run()` |
| `App` | struct | `ocwd/ocwd.v` | supervisor state: procs, channels, listen fd |
| `App.run` | fn | `ocwd/ocwd.v` | `select` on req / death / tick channels |
| `App.tick` | fn | `ocwd/ocwd.v` | starts opencode, then openchamber when port ready |
| `App.on_death` | fn | `ocwd/ocwd.v` | backoff, respawn, cascade stop openchamber |
| `spawn_proc` | fn | `ocwd/ocwd.v` | creates `os.Process`, sets env/cwd/pgroup, starts `log_pump` goroutine |
| `cmd_version` | fn | `ocwd/ocwd.v` | reports running and on-disk versions of supervised binaries |
| `cmd_reload` | fn | `ocwd/ocwd.v` | re-reads `state.json` and configured env file, adjusts processes |
| `adopt_existing_proc` | fn | `ocwd/ocwd.v` | adopts an already-running process on daemon startup |
| `log_msg` | fn | `ocwd/ocwd.v` | writes to `daemon.log` and to stderr in foreground mode |
| `find_pid_by_cmd` | fn | `ocwd/ocwd.v` | scans `/proc` to find a process matching a command name |
| `handle_client` | fn | `ocwd/ocwd.v` | decodes JSON command, routes to `handle_req` |
| `main` | fn | `ocw/ocw.v` | CLI argument dispatch (`status`, `cwd`, `restart`, etc.) |
| `print_latest` | fn | `ocw/ocw.v` | fetches latest online versions (GitHub releases / npm) in parallel; silent when offline |
| `send_recv_one` | fn | `ocw/ocw.v` | connects to socket, sends JSON, returns one line |
| `c_connect` | fn | `ocw/ocw.v` | AF_UNIX client socket setup |
| `c_listen` | fn | `ocwd/ocwd.v` | AF_UNIX server socket setup + bind/listen |
| `c_recv_line` | fn | `common.v:70` | reads one newline-terminated line from socket |
| `sock_path` | const | `common.v:30` | `/run/ocwd/ocwd.sock` |
| `opencode_port` | const | `ocwd/ocwd.v` | `4096` |
| `openchamber_port` | const | `ocwd/ocwd.v` | `4097` |

## CONVENTIONS

- **Indentation:** tabs (enforced by `v fmt`).
- **String emptiness:** use `s == ''` / `s != ''` (not `s.len == 0` / `s.len > 0`).
- **Module:** every `.v` file is `module main`; no V modules/packages used.
- **Shared code:** `ocw/common.v` and `ocwd/common.v` are symlinks to the root `common.v`. Editing the root file is enough.
- **C interop:** socket/bind/listen/accept declared in V via `fn C.*` and used in `unsafe` blocks.
- **Error handling:** `or { return / continue / default }` pattern; propagation via JSON `AckResp`.

## ANTI-PATTERNS (THIS PROJECT)

- **Do not set `have_proc = false` inside `restart_proc`.** The death event from `log_pump` is the single respawn trigger; clearing it early can cause duplicate processes while a port is still releasing.
- **Do not ignore the `pr.p.pid != msg.pid` guard in `on_death`.** Stale death reports from a previous incarnation must be ignored.
- **Do not break the `opencode` → `openchamber` dependency.** `openchamber` is only started once `opencode` is alive and its port is occupied.
- **Do not hardcode production values in a generic way.** Paths like `/etc/opencode-web.conf`, `/run/ocwd`, and binary paths are fixed and Linux-specific.

## UNIQUE STYLES

- **Manual C globals in `globals.h`:** V's `module main` has no mutable module globals, so C statics store the listen fd and pids for the signal handler.
- **Log pump per process:** each spawned process gets its own goroutine (`log_pump`) that drains stdout/stderr into a file and sends a `DeathMsg` on exit.
- **JSON line protocol:** client sends one JSON line, daemon replies with one JSON line (`\n` terminated). `logs` op keeps the socket open for streaming.
- **Back-off table:** explicit `1, 2, 4, 8, 16, 30` seconds in `backoff_for`.
- **Port occupancy as health check:** `port_free` dials the TCP port to decide if a process is "listening".

## COMMANDS

```bash
# Build & install ocwd and ocw
./build.sh

# Format / lint all V files
v fmt -w .
v vet .

# Run daemon (auto-backgrounds)
ocwd

# Run daemon in foreground-ish mode for debugging
ocwd --foreground
ocwd --no-daemon

# Use a custom environment file
ocwd --config /path/to/env.conf
ocwd --env-file /path/to/env.conf

# Reload a running daemon without restarting it
ocwd --reload

# Stop the running daemon completely (supervised processes included)
ocwd --shutdown

# Show daemon version/help
ocwd --version
ocwd --help

# CLI usage
ocw                   # bare ocw = ocw status + hint to run 'ocw help'
ocw status
ocw cwd
ocw cwd set [/some/dir]
ocw restart [opencode|openchamber|all]
ocw stop    [opencode|openchamber|all]
ocw start   [opencode|openchamber|all]
ocw reload
ocw logs    [opencode|openchamber] [-f] [tail N]
ocw version [opencode|openchamber|ocwd|all]
ocw shutdown
ocw help              # usage on stdout (also: --help, -h)

# Lookup cwd of a process
procwd <pid|name> [pid|name...]
procwd --version
```

## NOTES

- `common.v` is **not** a shared V module; it is reused via symlinks from `ocw/` and `ocwd/`. Consider extracting a real V module if the project grows.
- The `ocwd` daemon writes to `/run/ocwd`, which usually requires root or a prepared directory.
- `procwd` is a standalone helper; it does not talk to the daemon but is built by `build.sh` like the other binaries.
- The codegraph index in this workspace spans multiple projects, so `codegraph_*` queries may return unrelated symbols; prefer direct file reads for this repo.
- `ocwd --config` and `ocwd --env-file` override the default `/etc/opencode-web.conf` path; `ocw reload` re-reads the configured file on a running daemon.
- `ocwd` can adopt already-running `opencode` / `openchamber` processes on startup, provided their `cmdline` contains the expected `--port` argument.
- `ocw version` handles interpreter-launched binaries (e.g. `openchamber` under Node) and reports both the application version and the interpreter version.
