# manage-oc — Project Knowledge Base

**Generated:** 2026-07-15
**Language:** V (vlang) 0.5.2
**Stack:** V + inline C Unix sockets + `os.Process` supervisor + JSON line protocol

## OVERVIEW

`manage-oc` is a small process supervisor for local `opencode` / `openchamber` instances.
It consists of a Unix-socket daemon (`ocd`), a CLI client (`oc`), and a tiny `procwd` helper.

## STRUCTURE

```
.
├── common.v           # shared socket/protocol definitions (symlinked from oc/, ocd/)
├── build.sh           # compiles ocd & oc to /usr/local/bin
├── oc/
│   ├── common.v       # same as root common.v
│   └── oc.v           # CLI client: status | cwd | start | stop | restart | logs | shutdown
├── ocd/
│   ├── common.v       # same as root common.v
│   ├── globals.h      # C globals shared with SIGTERM/SIGINT handler
│   └── ocd.v          # daemon + supervisor loop
└── procwd/
    ├── procwd         # compiled binary
    └── procwd.v       # utility: print cwd of process by pid or name
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Build / install binaries | `build.sh` | `v -prod ocd/ -o /usr/local/bin/ocd` |
| Daemon supervisor logic | `ocd/ocd.v` | spawn, restart, backoff, logging, signal handling |
| CLI client commands | `oc/oc.v` | `main()` dispatch + `do_*` helpers |
| Shared protocol structs | `common.v` / `oc/common.v` / `ocd/common.v` | `Command`, `StatusResp`, `AckResp`, socket helpers |
| C globals for signal handler | `ocd/globals.h` | `g_ocd_pids`, `g_ocd_listen` |
| Process cwd lookup | `procwd/procwd.v` | reads `/proc/<pid>/cwd` |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `main` | fn | `ocd/ocd.v:801` | forks via `daemonize` unless `--foreground`/`--no-daemon` |
| `run_daemon` | fn | `ocd/ocd.v:720` | pidfile, socket, signal setup, `App.run()` |
| `App` | struct | `ocd/ocd.v:245` | supervisor state: procs, channels, listen fd |
| `App.run` | fn | `ocd/ocd.v:698` | `select` on req / death / tick channels |
| `App.tick` | fn | `ocd/ocd.v:365` | starts opencode, then openchamber when port ready |
| `App.on_death` | fn | `ocd/ocd.v:387` | backoff, respawn, cascade stop openchamber |
| `spawn_proc` | fn | `ocd/ocd.v:319` | creates `os.Process`, sets env/cwd/pgroup, starts `log_pump` goroutine |
| `handle_client` | fn | `ocd/ocd.v:642` | decodes JSON command, routes to `handle_req` |
| `main` | fn | `oc/oc.v:193` | CLI argument dispatch (`status`, `cwd`, `restart`, etc.) |
| `send_recv_one` | fn | `oc/oc.v:57` | connects to socket, sends JSON, returns one line |
| `c_connect` | fn | `oc/oc.v:6` | AF_UNIX client socket setup |
| `c_listen` | fn | `ocd/ocd.v:177` | AF_UNIX server socket setup + bind/listen |
| `c_recv_line` | fn | `common.v:70` | reads one newline-terminated line from socket |
| `sock_path` | const | `common.v:30` | `/run/ocd/ocd.sock` |
| `opencode_port` | const | `ocd/ocd.v:30` | `4096` |
| `openchamber_port` | const | `ocd/ocd.v:31` | `4097` |

## CONVENTIONS

- **Indentation:** tabs (enforced by `v fmt`).
- **String emptiness:** use `s == ''` / `s != ''` (not `s.len == 0` / `s.len > 0`).
- **Module:** every `.v` file is `module main`; no V modules/packages used.
- **Shared code:** `oc/common.v` and `ocd/common.v` are symlinks to the root `common.v`. Editing the root file is enough.
- **C interop:** socket/bind/listen/accept declared in V via `fn C.*` and used in `unsafe` blocks.
- **Error handling:** `or { return / continue / default }` pattern; propagation via JSON `AckResp`.

## ANTI-PATTERNS (THIS PROJECT)

- **Do not set `have_proc = false` inside `restart_proc`.** The death event from `log_pump` is the single respawn trigger; clearing it early can cause duplicate processes while a port is still releasing.
- **Do not ignore the `pr.p.pid != msg.pid` guard in `on_death`.** Stale death reports from a previous incarnation must be ignored.
- **Do not break the `opencode` → `openchamber` dependency.** `openchamber` is only started once `opencode` is alive and its port is occupied.
- **Do not hardcode production values in a generic way.** Paths like `/etc/opencode-web.conf`, `/run/ocd`, and binary paths are fixed and Linux-specific.

## UNIQUE STYLES

- **Manual C globals in `globals.h`:** V's `module main` has no mutable module globals, so C statics store the listen fd and pids for the signal handler.
- **Log pump per process:** each spawned process gets its own goroutine (`log_pump`) that drains stdout/stderr into a file and sends a `DeathMsg` on exit.
- **JSON line protocol:** client sends one JSON line, daemon replies with one JSON line (`\n` terminated). `logs` op keeps the socket open for streaming.
- **Back-off table:** explicit `1, 2, 4, 8, 16, 30` seconds in `backoff_for`.
- **Port occupancy as health check:** `port_free` dials the TCP port to decide if a process is "listening".

## COMMANDS

```bash
# Build & install ocd and oc
./build.sh

# Format / lint all V files
v fmt -w .
v vet .

# Run daemon (auto-backgrounds)
ocd

# Run daemon in foreground-ish mode for debugging
ocd --foreground
ocd --no-daemon

# CLI usage
oc status
oc cwd
oc cwd set [/some/dir]
oc restart [opencode|openchamber|all]
oc stop    [opencode|openchamber|all]
oc start   [opencode|openchamber|all]
oc logs    [opencode|openchamber] [-f] [tail N]
oc shutdown

# Lookup cwd of a process
procwd <pid|name>
```

## NOTES

- `common.v` is **not** a shared V module; it is reused via symlinks from `oc/` and `ocd/`. Consider extracting a real V module if the project grows.
- The `ocd` daemon writes to `/run/ocd`, which usually requires root or a prepared directory.
- `procwd` is a standalone helper; it does not talk to the daemon and is not built by `build.sh`.
- The codegraph index in this workspace spans multiple projects, so `codegraph_*` queries may return unrelated symbols; prefer direct file reads for this repo.
