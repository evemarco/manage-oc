// C globals shared with the signal handler (no mutable V module globals in `module main`).
// These let SIGTERM/SIGINT cleanly kill the supervised process groups and remove
// the socket/pidfile even though the handler cannot reach the `App` struct.
#ifndef OCWD_GLOBALS_H
#define OCWD_GLOBALS_H
static int g_ocwd_pids[2] = { 0, 0 }; // [0] = opencode pid, [1] = openchamber pid
static int g_ocwd_listen = -1;        // control socket listen fd
static volatile int g_ocwd_reload = 0; // SIGHUP flag
static volatile int g_ocwd_restart = 0; // SIGUSR2 self-exec flag
static volatile int g_ocwd_foreground = 0; // foreground mode flag
static inline int ocwd_get_listen() { return g_ocwd_listen; }
static inline void ocwd_set_listen(int v) { g_ocwd_listen = v; }
static inline int ocwd_get_pid(int i) { return g_ocwd_pids[i]; }
static inline void ocwd_set_pid(int i, int v) { g_ocwd_pids[i] = v; }
static inline int ocwd_get_reload() { return g_ocwd_reload; }
static inline void ocwd_set_reload(int v) { g_ocwd_reload = v; }
static inline int ocwd_get_restart() { return g_ocwd_restart; }
static inline void ocwd_set_restart(int v) { g_ocwd_restart = v; }
static inline int ocwd_get_foreground() { return g_ocwd_foreground; }
static inline void ocwd_set_foreground(int v) { g_ocwd_foreground = v; }
#endif
