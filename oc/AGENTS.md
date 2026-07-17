# oc/ — CLI client

## OVERVIEW
`oc` is the command-line client that connects to the `ocd` daemon over `/run/ocd/ocd.sock` and issues JSON-line commands.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `oc.v` | dispatches subcommands |
| `c_connect` | `oc.v` | creates AF_UNIX client socket |
| `connect` | `oc.v` | wraps `c_connect`; exits if socket missing |
| `send_recv_one` | `oc.v` | sends one JSON command and reads one response |
| `do_status` | `oc.v` | pretty-prints daemon status table |
| `do_cwd` | `oc.v` | `oc cwd` and `oc cwd set [dir]` |
| `do_simple` | `oc.v` | `restart`, `stop`, `start`, `reload`, `shutdown` |
| `do_logs` | `oc.v` | streaming logs with `-f` and optional `tail N` |
| `do_version` | `oc.v` | `oc version` and `oc version <target>` |
| `is_int` | `oc.v` | validates numeric tail argument |
| `Command`/`StatusResp`/`AckResp` | `common.v` | shared protocol structs |

## UNIQUE STYLES
- Single-shot commands use `send_recv_one`, which opens the socket, writes one JSON line, reads one line, then closes.
- `do_logs` keeps the socket open and streams lines until the daemon closes it or `__END__` arrives.
- `connect` exits the process with code 1 when the daemon socket is absent; don't call it if you want to recover.
- `do_simple` reads the optional third argument (`args[2]`) as the target, defaulting to empty string.

## COMMANDS

```bash
oc status
oc cwd
oc cwd set [dir]
oc restart [opencode|openchamber|all]
oc stop    [opencode|openchamber|all]
oc start   [opencode|openchamber|all]
oc reload
oc logs    [opencode|openchamber] [-f] [tail N]
oc version [opencode|openchamber|ocd|all]
oc shutdown
```

## NOTES
- `do_logs` uses `__END__` as a sentinel for non-follow mode; do not remove it.
- `oc/common.v` is a symlink to the root `common.v`, not a module; changes only need to be made in the root file.
- Unknown commands and usage errors exit with code 2; daemon or protocol errors exit with code 1.
