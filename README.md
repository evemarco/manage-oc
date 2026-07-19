# manage-oc

A small process supervisor for local `opencode` / `openchamber` instances.

`manage-oc` runs a Unix-socket daemon (`ocwd`) that keeps `opencode` and `openchamber` alive, and provides a tiny CLI client (`ocw`) to control it. A separate utility, `procwd`, prints the working directory of a process by PID or name.

## Table of contents

- [Overview](#overview)
- [Why manage-oc?](#why-manage-oc)
- [Architecture](#architecture)
- [Build & install](#build--install)
- [Migrating from 0.2.x](#migrating-from-02x)
- [The `ocwd` daemon](#the-ocwd-daemon)
- [The `ocw` client](#the-ocw-client)
- [The `procwd` helper](#the-procwd-helper)
- [Configuration](#configuration)
- [Development](#development)
- [Project notes](#project-notes)

## Overview

| Component | Purpose | Built by `build.sh` |
|-----------|---------|---------------------|
| `ocwd` | Supervisor daemon that starts/stops/monitors `opencode` and `openchamber` | yes |
| `ocw` | CLI client that talks to `ocwd` over a Unix socket | yes |
| `procwd` | Standalone utility that prints a process CWD | yes |

The daemon uses a JSON line protocol over `/run/ocwd/ocwd.sock`. The client sends one JSON command per line; the daemon replies with one JSON line per command (except for log streaming, which keeps the connection open).

## Why manage-oc?

`manage-oc` was created to make it easier to run **openchamber behind a reverse proxy**. See the openchamber documentation for the recommended reverse-proxy setup: [https://docs.openchamber.dev/reverse-proxy/](https://docs.openchamber.dev/reverse-proxy/).

Beyond process supervision, it solves a practical working-directory problem. You can run the `ocw` client from **any terminal** — a real terminal on your machine, or the JavaScript terminal built into openchamber's web interface — to change the working directory of the supervised processes on the fly. This is especially useful because many plugins and LSP servers rely on the current working directory (`cwd`) to resolve project files, imports, or configuration. With `ocw cwd set /path/to/project` (or just `ocw cwd set` to use the directory from which you run `ocw`), you can switch the daemon's working directory without restarting the whole stack, and the supervised processes will pick up the new `cwd` when they respawn.

### Why openchamber?

openchamber provides a more complete interface than opencode web, while remaining compatible with plugins such as **oh-my-openagent** for profile selection. It is available as a web interface, as native applications for Windows, Android, and macOS, and as a Progressive Web App (PWA) — the PWA option being particularly useful on Linux.

## Architecture

```text
┌──────────┐     AF_UNIX /run/ocwd/ocwd.sock     ┌──────────┐
│   ocw    │  ───────────────────────────────▶   │   ocwd   │
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

- `ocwd` is started once and daemonizes itself with `setsid --fork`.
- It listens on `/run/ocwd/ocwd.sock` for commands.
- It spawns `opencode` on port `4096`.
- It spawns `openchamber` on port `4097` **only after** `opencode` is confirmed listening.
- If a process dies, the daemon waits for a backoff interval (`1, 2, 4, 8, 16, 30` seconds), then restarts it.
- Each spawned process gets its own goroutine that drains stdout/stderr into a per-process log file under `/run/ocwd/logs/`.

## Build & install

```bash
./build.sh
```

This compiles `ocwd`, `ocw`, and `procwd` with `v -prod` and installs them to `/usr/local/bin`.

Requirements:

- [V](https://vlang.io/) (tested with V 0.5.2)
- Linux (uses `/proc`, `AF_UNIX`, and `setsid`)
- A writable `/run/ocwd` directory for the runtime socket, PID file, state, and logs

## Migrating from 0.2.x

The 0.3.0 release renames the client from `oc` to `ocw`, the daemon from `ocd` to `ocwd`, and the runtime directory from `/run/ocd` to `/run/ocwd`.

Stop the old daemon before installing the renamed binaries:

```bash
/usr/local/bin/ocd --shutdown
./build.sh
ocwd
ocw status
```

On its first start, `ocwd` copies the old `/run/ocd/state.json` into `/run/ocwd/state.json` when the new state does not exist. It refuses to start while the legacy `ocd` daemon is still running, preventing two supervisors from managing the same processes.

The build does not delete `/usr/local/bin/oc` or `/usr/local/bin/ocd`: either name might belong to unrelated software. Inspect them with `type -a` and `--version`, then remove them only if they are confirmed to be legacy manage-oc binaries.

## The `ocwd` daemon

### Start the daemon

```bash
ocwd
```

By default `ocwd` backgrounds itself. `ocwd --daemon` is equivalent and exists for explicit scripts. To run in the foreground for debugging:

```bash
ocwd --foreground
# or
ocwd --no-daemon
```

Set the initial working directory on startup:

```bash
ocwd --cwd /some/path
```

Use a custom environment file instead of `/etc/opencode-web.conf`:

```bash
ocwd --config /path/to/env.conf
# or
ocwd --env-file /path/to/env.conf
```

Reload a running daemon's configuration without restarting it:

```bash
ocwd --reload
```

Show daemon version or help:

```bash
ocwd --version
ocwd --help
```

### Stop the daemon

```bash
ocw shutdown
# or, without the client:
ocwd --shutdown
```

Both stop the supervised processes and the daemon itself. You can also send `SIGTERM` / `SIGINT` to the daemon process.

### Runtime files

| Path | Purpose |
|------|---------|
| `/run/ocwd/ocwd.sock` | Unix socket for client commands |
| `/run/ocwd/ocwd.pid` | PID file of the daemon |
| `/run/ocwd/daemon.log` | Daemon's own stdout/stderr log |
| `/run/ocwd/state.json` | Persisted state (cwd, enabled flags) |
| `/run/ocwd/logs/opencode.log` | `opencode` stdout/stderr |
| `/run/ocwd/logs/openchamber.log` | `openchamber` stdout/stderr |

## The `ocw` client

```bash
ocw                   # same as 'ocw status', plus a hint about 'ocw help'
ocw status
ocw cwd
ocw cwd set [/some/dir]
ocw cwd /some/dir
ocw start   [opencode|openchamber|all]
ocw stop    [opencode|openchamber|all]
ocw restart [opencode|openchamber|all]
ocw reload
ocw logs    [opencode|openchamber] [-f] [tail N]
ocw version [opencode|openchamber|ocwd|all]
ocw shutdown
ocw help              # show usage (also: --help, -h)
```

Results are printed to stdout; errors go to stderr. Exit codes: `0` on success, `1` for daemon or protocol errors (including unknown targets), `2` for unknown commands.

Use `ocw version` to check the versions of `ocw`, `ocwd`, and the running supervised processes. It also warns when a running binary no longer matches the on-disk executable (for example after an update).

When the machine has internet access, `ocw version` also queries the latest published versions — opencode (GitHub releases), openchamber (npm `@openchamber/web`), and manage-oc itself (GitHub releases) — and prints them in a `latest (online)` section so you can see at a glance whether an update is available. When offline, this section is silently omitted.

### Examples

Show daemon status:

```bash
ocw status
```

Get or set the working directory used by the supervised processes:

```bash
ocw cwd
ocw cwd set /root/my-project
ocw cwd set              # use the current directory
ocw cwd /root/my-project
```

Restart `opencode` (and automatically restart `openchamber` because it depends on it):

```bash
ocw restart opencode
```

Show the last 50 log lines for `opencode`:

```bash
ocw logs opencode
```

Follow the `opencode` log in real time:

```bash
ocw logs opencode -f
```

Show the last 100 lines:

```bash
ocw logs opencode 100
ocw logs opencode tail 100
```

Reload the daemon's configuration and state without restarting it:

```bash
ocw reload
```

Check versions of the client, daemon, and supervised processes:

```bash
ocw version
ocw version opencode
ocw version openchamber
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

The daemon reads a simple key-value file and injects its variables into the environment of the spawned processes. By default the file is `/etc/opencode-web.conf`; you can override it with `ocwd --config <path>` or `ocwd --env-file <path>`. The file is optional; if it is missing, no extra environment variables are added. `ocw reload` re-reads the configured file on a running daemon.

```text
# /etc/opencode-web.conf
# Lines starting with # or ; are ignored, as are blank lines.
KEY=value
```

The daemon also persists state to `/run/ocwd/state.json`, which currently stores:

- the current working directory (`cwd`)
- whether each process is enabled (`opencode`, `openchamber`)

### Example configuration file

A typical `/etc/opencode-web.conf` for `opencode` and `openchamber` might look like this:

```text
# /etc/opencode-web.conf
# Environment variables injected into opencode and openchamber by ocwd.

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

- `ocwd` sets `OPENCODE_SKIP_START=true` for the `openchamber` process automatically so openchamber does not spawn its own `opencode`. You do not need to set it in this file.
- To protect the OpenChamber web UI with a password, set `OPENCHAMBER_UI_PASSWORD` in this file or pass `--ui-password` when starting `openchamber`.
- The actual variables understood by `opencode` and `openchamber` depend on their versions and CLI argument parsers. Use the binaries' `--help` output to discover the exact environment variables they support.
- `ocwd` already passes `--port`, `--hostname`, and `--print-logs` to `opencode`, and `--port`, `--host`, and `--foreground` to `openchamber` via CLI arguments. Some of these may be overridden by environment variables depending on how the binaries are implemented.

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
ocwd --foreground
# or
ocwd --no-daemon
```

## Project notes

- Every `.v` file declares `module main`; there are no shared V modules. The `common.v` file at the repository root is reused in `ocw/` and `ocwd/` via symlinks. Any protocol change only needs to be made in the root `common.v`.
- The root `common.v` is **not** used by the builds; `ocw/` and `ocwd/` compile only their own directory contents.
- Unix socket operations are done with inline C bindings (`fn C.*`) because V does not have a native `AF_UNIX` API.
- The daemon uses C globals in `ocwd/globals.h` so that the `SIGTERM`/`SIGINT` handler can cleanly kill the supervised process groups and remove the socket/pidfile.
- `ocwd` can adopt already-running `opencode` / `openchamber` processes on startup, which lets you restart or upgrade the daemon without killing the supervised processes.
- `ocw version` detects interpreter-launched binaries (e.g. `openchamber` running under Node) and reports both the application version and the interpreter version.
- All runtime paths (`/run/ocwd`, `/etc/opencode-web.conf`, the binary paths) are hardcoded and Linux-specific. The configuration file path can be overridden with `ocwd --config`.

## License

MIT
