// C globals shared with the signal handler (no mutable V module globals in `module main`).
// These let SIGTERM/SIGINT cleanly kill the supervised process groups and remove
// the socket/pidfile even though the handler cannot reach the `App` struct.
#ifndef OCD_GLOBALS_H
#define OCD_GLOBALS_H
static int g_ocd_pids[2] = { 0, 0 }; // [0] = opencode pid, [1] = openchamber pid
static int g_ocd_listen = -1;        // control socket listen fd
static inline int ocd_get_listen() { return g_ocd_listen; }
static inline void ocd_set_listen(int v) { g_ocd_listen = v; }
static inline int ocd_get_pid(int i) { return g_ocd_pids[i]; }
static inline void ocd_set_pid(int i, int v) { g_ocd_pids[i] = v; }
#endif
