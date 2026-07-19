module main

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

// ---- inline-C Unix socket bindings (V has no native AF_UNIX API) ----
fn C.socket(int, int, int) int
fn C.bind(int, voidptr, int) int
fn C.listen(int, int) int
fn C.accept(int, voidptr, voidptr) int
fn C.connect(int, voidptr, int) int
fn C.send(int, voidptr, int, int) int
fn C.recv(int, voidptr, int, int) int
fn C.close(int) int
fn C.unlink(&char) int
fn C.strcpy(&char, &char) &char
fn C.memset(voidptr, int, int) voidptr
fn C.kill(int, int) int
fn C.open(&char, int, int) int
fn C.dup2(int, int) int

struct C.sockaddr_un {
	sun_family u16
	sun_path   [108]char
}

// ---- shared runtime path ----
const sock_path = '/run/ocwd/ocwd.sock'

// ---- protocol types ----
struct Command {
	op     string
	target string
	arg    string
	arg2   string
}

struct ProcInfo {
	name       string
	pid        int
	cwd        string
	state      string
	listening  bool
	uptime_sec int
	restarts   int
}

struct StatusResp {
	daemon_pid int
	cwd        string
	procs      []ProcInfo
}

struct AckResp {
	ok  bool
	msg string
}

// ---- C socket helpers ----
fn c_send_str(fd int, s string) int {
	if fd < 0 {
		return -1
	}
	return C.send(fd, s.str, s.len, 0)
}

// read a single newline-terminated line (without the newline). returns '' on EOF/close.
fn c_recv_line(fd int) string {
	if fd < 0 {
		return ''
	}
	mut buf := []u8{cap: 256}
	mut b := [1]u8{}
	for {
		n := C.recv(fd, &b[0], 1, 0)
		if n <= 0 {
			break
		}
		if b[0] == `\r` {
			continue
		}
		if b[0] == `\n` {
			break
		}
		buf << b[0]
	}
	return buf.bytestr()
}

fn c_close(fd int) {
	if fd >= 0 {
		C.close(fd)
	}
}
