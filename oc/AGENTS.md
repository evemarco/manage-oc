# oc/ — CLI client

## OVERVIEW
`oc` is the command-line client that connects to the `ocd` daemon over `/run/ocd/ocd.sock` and issues JSON-line commands.

## WHERE TO LOOK

| Symbol | Location | Role |
|--------|----------|------|
| `main` | `oc.v:193` | dispatches subcommands |
| `c_connect` | `oc.v:6` | creates AF_UNIX client socket |
| `connect` | `oc.v:35` | wraps `c_connect`; exits if socket missing |
| `send_recv_one` | `oc.v:57` | sends one JSON command and reads one response |
| `do_status` | `oc.v:72` | pretty-prints daemon status table |
| `do_cwd` | `oc.v:96` | `oc cwd` and `oc cwd set <dir>` |
| `do_simple` | `oc.v:128` | `restart`, `stop`, `start`, `shutdown` |
| `do_logs` | `oc.v:141` | streaming logs with `-f` and optional `tail N` |
| `is_int` | `oc.v:44` | validates numeric tail argument |
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
oc cwd set <dir>
oc restart [opencode|openchamber|all]
oc stop    [opencode|openchamber|all]
oc start   [opencode|openchamber|all]
oc logs    [opencode|openchamber] [-f] [tail N]
oc shutdown
```

## NOTES
- `do_logs` uses `__END__` as a sentinel for non-follow mode; do not remove it.
- `common.v` is a copy, not a module; changes here must be mirrored in `ocd/common.v` and the root `common.v`.
- Unknown commands and usage errors exit with code 2; daemon or protocol errors exit with code 1.
