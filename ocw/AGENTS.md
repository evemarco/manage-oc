# ocw/ — CLI client

## OVERVIEW
`ocw` is the command-line client that connects to the `ocwd` daemon over `/run/ocwd/ocwd.sock` and issues JSON-line commands.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `ocw.v` | dispatches subcommands |
| `c_connect` | `ocw.v` | creates AF_UNIX client socket |
| `connect` | `ocw.v` | wraps `c_connect`; exits if socket missing |
| `send_recv_one` | `ocw.v` | sends one JSON command and reads one response |
| `do_status` | `ocw.v` | pretty-prints daemon status table |
| `do_cwd` | `ocw.v` | `ocw cwd` and `ocw cwd set [dir]` |
| `do_simple` | `ocw.v` | `restart`, `stop`, `start`, `reload`, `shutdown` |
| `do_logs` | `ocw.v` | streaming logs with `-f` and optional `tail N` |
| `do_version` | `ocw.v` | `ocw version` and `ocw version <target>` |
| `print_latest`/`fetch_latest` | `ocw.v` | fetches online latest versions in parallel (GitHub releases / npm), silent on failure |
| `usage` | `ocw.v` | prints usage to stdout (`false`) or stderr (`true`) |
| `is_int` | `ocw.v` | validates numeric tail argument |
| `Command`/`StatusResp`/`AckResp` | `common.v` | shared protocol structs |

## UNIQUE STYLES
- Single-shot commands use `send_recv_one`, which opens the socket, writes one JSON line, reads one line, then closes.
- `do_logs` keeps the socket open and streams lines until the daemon closes it or `__END__` arrives.
- `connect` exits the process with code 1 when the daemon socket is absent; don't call it if you want to recover.
- `do_simple` reads the optional third argument (`args[2]`) as the target, defaulting to empty string.

## COMMANDS

```bash
ocw                   # bare ocw = ocw status + hint to run 'ocw help'
ocw status
ocw cwd
ocw cwd set [dir]
ocw restart [opencode|openchamber|all]
ocw stop    [opencode|openchamber|all]
ocw start   [opencode|openchamber|all]
ocw reload
ocw logs    [opencode|openchamber] [-f] [tail N]
ocw version [opencode|openchamber|ocwd|all]
ocw shutdown
ocw help              # usage on stdout (also: --help, -h)
```

## NOTES
- `do_logs` uses `__END__` as a sentinel for non-follow mode; do not remove it.
- `ocw/common.v` is a symlink to the root `common.v`, not a module; changes only need to be made in the root file.
- Unknown commands and usage errors exit with code 2; daemon or protocol errors exit with code 1.
- stdout/stderr convention: results go to stdout, errors to stderr. `usage(false)` prints to stdout (`ocw help`), `usage(true)` prints to stderr (after an unknown command). Keep `!ack.ok` checks printing via `eprintln` with `exit(1)`.
- Online version checks live in the client, never in `ocwd` (its `select` loop must not block on network). Sources: GitHub releases for opencode (`anomalyco/opencode`) and manage-oc (`evemarco/manage-oc`), npm registry for openchamber (`@openchamber/web`). 2s read timeout, parallel goroutines, silent on any failure.
