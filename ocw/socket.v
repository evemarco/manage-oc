module main

import json2

fn c_connect(path string) int {
	fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	if fd < 0 {
		return -1
	}
	unsafe {
		addr := &C.sockaddr_un{}
		C.memset(addr, 0, int(sizeof(C.sockaddr_un)))
		addr.sun_family = u16(C.AF_UNIX)
		C.strcpy(&addr.sun_path[0], path.str)
		if C.connect(fd, addr, int(sizeof(C.sockaddr_un))) != 0 {
			C.close(fd)
			return -1
		}
	}
	return fd
}

fn connect() int {
	fd := c_connect(sock_path)
	if fd < 0 {
		eprintln('ocw: ocwd not started (no socket at ' + sock_path + ')')
		exit(1)
	}
	return fd
}

// send a command and read a single JSON response line.
fn send_recv_one(cmd Command) string {
	fd := connect()
	defer { c_close(fd) }
	c_send_str(fd, json2.encode(cmd) + '\n')
	return c_recv_line(fd)
}
