# manage-oc

A small process supervisor for local `opencode` / `openchamber` instances.

`manage-oc` runs a Unix-socket daemon (`ocd`) that keeps `opencode` and `openchamber` alive, and provides a tiny CLI client (`oc`) to control it. A separate utility, `procwd`, prints the working directory of a process by PID or name.

## Table of contents

- [Overview](#overview)
- [Why manage-oc?](#why-manage-oc)
- [Architecture](#architecture)
- [Build & install](#build--install)
- [The `ocd` daemon](#the-ocd-daemon)
- [The `oc` client](#the-oc-client)
- [The `procwd` helper](#the-procwd-helper)
- [Configuration](#configuration)
- [Development](#development)
- [Project notes](#project-notes)

## Overview

| Component | Purpose | Built by `build.sh` |
|-----------|---------|---------------------|
| `ocd` | Supervisor daemon that starts/stops/monitors `opencode` and `openchamber` | yes |
| `oc` | CLI client that talks to `ocd` over a Unix socket | yes |
| `procwd` | Standalone utility that prints a process CWD | yes |

The daemon uses a JSON line protocol over `/run/ocd/ocd.sock`. The client sends one JSON command per line; the daemon replies with one JSON line per command (except for log streaming, which keeps the connection open).

## Why manage-oc?

`manage-oc` was created to make it easier to run **openchamber behind a reverse proxy**. See the openchamber documentation for the recommended reverse-proxy setup: [https://docs.openchamber.dev/reverse-proxy/](https://docs.openchamber.dev/reverse-proxy/).

Beyond process supervision, it solves a practical working-directory problem. You can run the `oc` client from **any terminal** — a real terminal on your machine, or the JavaScript terminal built into openchamber's web interface — to change the working directory of the supervised processes on the fly. This is especially useful because many plugins and LSP servers rely on the current working directory (`cwd`) to resolve project files, imports, or configuration. With `oc cwd set /path/to/project` (or just `oc cwd set` to use the directory from which you run `oc`), you can switch the daemon's working directory without restarting the whole stack, and the supervised processes will pick up the new `cwd` when they respawn.

### Why openchamber?

openchamber provides a more complete interface than opencode web, while remaining compatible with plugins such as **oh-my-openagent** for profile selection. It is available as a web interface, as native applications for Windows, Android, and macOS, and as a Progressive Web App (PWA) — the PWA option being particularly useful on Linux.

## Architecture

```text
┌──────────┐      AF_UNIX /run/ocd/ocd.sock      ┌──────────┐
│   oc     │  ───────────────────────────────▶   │   ocd    │
│  client  │                                    │  daemon  │
└──────────┘                                    └────┬─────┘
                                                     │ spawns
                        ┌──────────────┬─────────────┘
                        ▼              ▼
                   ┌──────────┐   ┌──────────┐
                   │ opencode │   │openchamber│
                   │ :4096    │   │ :4097     │
                   └──────────┘   └──────────┘
```

- `ocd` is started once and daemonizes itself with `setsid --fork`.
- It listens on `/run/ocd/ocd.sock` for commands.
- It spawns `opencode` on port `4096`.
- It spawns `openchamber` on port `4097` **only after** `opencode` is confirmed listening.
- If a process dies, the daemon waits for a backoff interval (`1, 2, 4, 8, 16, 30` seconds), then restarts it.
- Each spawned process gets its own goroutine that drains stdout/stderr into a per-process log file under `/run/ocd/logs/`.

## Build & install

```bash
./build.sh
```

This compiles `ocd`, `oc`, and `procwd` with `v -prod` and installs them to `/usr/local/bin`.

Requirements:

- [V](https://vlang.io/) (tested with V 0.5.2)
- Linux (uses `/proc`, `AF_UNIX`, and `setsid`)
- A writable `/run/ocd` directory for the runtime socket, PID file, state, and logs

## The `ocd` daemon

### Start the daemon

```bash
ocd
```

By default `ocd` backgrounds itself. `ocd --daemon` is equivalent and exists for explicit scripts. To run in the foreground for debugging:

```bash
ocd --foreground
# or
ocd --no-daemon
```

Set the initial working directory on startup:

```bash
ocd --cwd /some/path
```

Use a custom environment file instead of `/etc/opencode-web.conf`:

```bash
ocd --config /path/to/env.conf
# or
ocd --env-file /path/to/env.conf
```

Reload a running daemon's configuration without restarting it:

```bash
ocd --reload
```

Show daemon version or help:

```bash
ocd --version
ocd --help
```

### Stop the daemon

```bash
oc shutdown
# or, without the client:
ocd --shutdown
```

Both stop the supervised processes and the daemon itself. You can also send `SIGTERM` / `SIGINT` to the daemon process.

### Runtime files

| Path | Purpose |
|------|---------|
| `/run/ocd/ocd.sock` | Unix socket for client commands |
| `/run/ocd/ocd.pid` | PID file of the daemon |
| `/run/ocd/daemon.log` | Daemon's own stdout/stderr log |
| `/run/ocd/state.json` | Persisted state (cwd, enabled flags) |
| `/run/ocd/logs/opencode.log` | `opencode` stdout/stderr |
| `/run/ocd/logs/openchamber.log` | `openchamber` stdout/stderr |

## The `oc` client

```bash
oc                   # same as 'oc status', plus a hint about 'oc help'
oc status
oc cwd
oc cwd set [/some/dir]
oc cwd /some/dir
oc start   [opencode|openchamber|all]
oc stop    [opencode|openchamber|all]
oc restart [opencode|openchamber|all]
oc reload
oc logs    [opencode|openchamber] [-f] [tail N]
oc version [opencode|openchamber|ocd|all]
oc shutdown
oc help              # show usage (also: --help, -h)
```

Results are printed to stdout; errors go to stderr. Exit codes: `0` on success, `1` for daemon or protocol errors (including unknown targets), `2` for unknown commands.

Use `oc version` to check the versions of `oc`, `ocd`, and the running supervised processes. It also warns when a running binary no longer matches the on-disk executable (for example after an update).

When the machine has internet access, `oc version` also queries the latest published versions — opencode (GitHub releases), openchamber (npm `@openchamber/web`), and manage-oc itself (GitHub releases) — and prints them in a `latest (online)` section so you can see at a glance whether an update is available. When offline, this section is silently omitted.

### Examples

Show daemon status:

```bash
oc status
```

Get or set the working directory used by the supervised processes:

```bash
oc cwd
oc cwd set /root/my-project
oc cwd set              # use the current directory
oc cwd /root/my-project
```

Restart `opencode` (and automatically restart `openchamber` because it depends on it):

```bash
oc restart opencode
```

Show the last 50 log lines for `opencode`:

```bash
oc logs opencode
```

Follow the `opencode` log in real time:

```bash
oc logs opencode -f
```

Show the last 100 lines:

```bash
oc logs opencode 100
oc logs opencode tail 100
```

Reload the daemon's configuration and state without restarting it:

```bash
oc reload
```

Check versions of the client, daemon, and supervised processes:

```bash
oc version
oc version opencode
oc version openchamber
```

## The `procwd` helper

`procwd` is a standalone utility that prints the current working directory of a process by PID or by process name.

```bash
procwd 1234
procwd opencode
procwd openchamber
```

It scans `/proc` for a matching PID or `comm`/`cmdline` and prints `pid: cwd` lines. If multiple processes match by name, all are printed.

## Configuration

The daemon reads a simple key-value file and injects its variables into the environment of the spawned processes. By default the file is `/etc/opencode-web.conf`; you can override it with `ocd --config <path>` or `ocd --env-file <path>`. The file is optional; if it is missing, no extra environment variables are added. `oc reload` re-reads the configured file on a running daemon.

```text
# /etc/opencode-web.conf
# Lines starting with # or ; are ignored, as are blank lines.
KEY=value
```

The daemon also persists state to `/run/ocd/state.json`, which currently stores:

- the current working directory (`cwd`)
- whether each process is enabled (`opencode`, `openchamber`)

### Example configuration file

A typical `/etc/opencode-web.conf` for `opencode` and `openchamber` might look like this:

```text
# /etc/opencode-web.conf
# Environment variables injected into opencode and openchamber by ocd.

# opencode variables
OPENCODE_HOST=127.0.0.1
OPENCODE_PORT=4096
OPENCODE_PRINT_LOGS=true

# openchamber variables
OPENCHAMBER_HOST=127.0.0.1
OPENCHAMBER_PORT=4097
OPENCHAMBER_UI_PASSWORD=your-secure-password
OPENCODE_SKIP_START=true
```

Notes:

- `ocd` sets `OPENCODE_SKIP_START=true` for the `openchamber` process automatically so openchamber does not spawn its own `opencode`. You do not need to set it in this file.
- To protect the OpenChamber web UI with a password, set `OPENCHAMBER_UI_PASSWORD` in this file or pass `--ui-password` when starting `openchamber`.
- The actual variables understood by `opencode` and `openchamber` depend on their versions and CLI argument parsers. Use the binaries' `--help` output to discover the exact environment variables they support.
- `ocd` already passes `--port`, `--hostname`, and `--print-logs` to `opencode`, and `--port`, `--host`, and `--foreground` to `openchamber` via CLI arguments. Some of these may be overridden by environment variables depending on how the binaries are implemented.

## Development

Format the V source files:

```bash
v fmt -w .
```

Lint the project:

```bash
v vet .
```

Run the daemon in the foreground for debugging:

```bash
ocd --foreground
# or
ocd --no-daemon
```

## Project notes

- Every `.v` file declares `module main`; there are no shared V modules. The `common.v` file at the repository root is reused in `oc/` and `ocd/` via symlinks. Any protocol change only needs to be made in the root `common.v`.
- The root `common.v` is **not** used by the builds; `oc/` and `ocd/` compile only their own directory contents.
- Unix socket operations are done with inline C bindings (`fn C.*`) because V does not have a native `AF_UNIX` API.
- The daemon uses C globals in `ocd/globals.h` so that the `SIGTERM`/`SIGINT` handler can cleanly kill the supervised process groups and remove the socket/pidfile.
- `ocd` can adopt already-running `opencode` / `openchamber` processes on startup, which lets you restart or upgrade the daemon without killing the supervised processes.
- `oc version` detects interpreter-launched binaries (e.g. `openchamber` running under Node) and reports both the application version and the interpreter version.
- All runtime paths (`/run/ocd`, `/etc/opencode-web.conf`, the binary paths) are hardcoded and Linux-specific. The configuration file path can be overridden with `ocd --config`.

## License

MIT
