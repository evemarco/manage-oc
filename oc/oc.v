module main

import os
import json
import v.vmod
import net.http
import time

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

fn usage(to_err bool) {
	lines := [
		'usage:',
		'  oc status',
		'  oc cwd [set [dir]] | <dir>',
		'  oc restart [opencode|openchamber|all]',
		'  oc stop    [opencode|openchamber|all]',
		'  oc start   [opencode|openchamber|all]',
		'  oc reload',
		'  oc logs    [opencode|openchamber] [-f] [tail N]',
		'  oc version [opencode|openchamber|ocd|all]',
		'  oc shutdown',
		'  oc help',
	]
	for line in lines {
		if to_err {
			eprintln(line)
		} else {
			println(line)
		}
	}
}

fn connect() int {
	fd := c_connect(sock_path)
	if fd < 0 {
		eprintln('oc: ocd not started (no socket at ' + sock_path + ')')
		exit(1)
	}
	return fd
}

fn is_int(s string) bool {
	if s == '' {
		return false
	}
	for ch in s {
		if ch < `0` || ch > `9` {
			return false
		}
	}
	return true
}

// send a command and read a single JSON response line.
fn send_recv_one(cmd Command) string {
	fd := connect()
	defer { c_close(fd) }
	c_send_str(fd, json.encode(cmd) + '\n')
	return c_recv_line(fd)
}

fn pad(s string, n int) string {
	mut r := s
	for r.len < n {
		r += ' '
	}
	return r
}

fn do_status() {
	resp := send_recv_one(Command{ op: 'status' })
	st := json.decode(StatusResp, resp) or {
		eprintln('oc: bad response: ' + resp)
		exit(1)
	}
	println('Daemon pid : ' + st.daemon_pid.str())
	println('CWD        : ' + st.cwd)
	println('')
	println(pad('PROC', 12) + pad('PID', 8) + pad('STATE', 10) + pad('LISTEN', 8) + pad('CWD', 23) +
		pad('UPTIME', 9) + 'RESTARTS')
	println('-------------------------------------------------------------------------------')
	for p in st.procs {
		mut uptime := p.uptime_sec.str() + 's'
		if p.uptime_sec >= 60 {
			uptime = '${p.uptime_sec / 60}m${p.uptime_sec % 60}s'
		}
		listen := if p.listening { 'yes' } else { 'no' }
		cwd := if p.cwd.len > 0 { p.cwd } else { '-' }
		println(pad(p.name, 12) + pad(p.pid.str(), 8) + pad(p.state, 10) + pad(listen, 8) +
			pad(cwd, 23) + pad(uptime, 9) + p.restarts.str())
	}
}

fn do_cwd(rest []string) {
	if rest.len == 0 {
		resp := send_recv_one(Command{ op: 'cwd', arg: 'get' })
		ack := json.decode(AckResp, resp) or {
			eprintln('oc: bad response: ' + resp)
			exit(1)
		}
		println('cwd: ' + ack.msg)
		return
	}
	mut dir := ''
	if rest[0] == 'set' {
		if rest.len < 2 {
			dir = os.getwd()
		} else {
			dir = rest[1]
		}
	} else {
		dir = rest[0]
	}
	resp := send_recv_one(Command{ op: 'cwd', arg: 'set', target: dir })
	ack := json.decode(AckResp, resp) or {
		eprintln('oc: bad response: ' + resp)
		exit(1)
	}
	if !ack.ok {
		eprintln('oc: ' + ack.msg)
		exit(1)
	}
	println(ack.msg)
}

fn do_simple(op string, args []string) {
	mut target := ''
	if args.len > 2 {
		target = args[2]
	}
	resp := send_recv_one(Command{ op: op, target: target })
	ack := json.decode(AckResp, resp) or {
		eprintln('oc: bad response: ' + resp)
		exit(1)
	}
	if !ack.ok {
		eprintln('oc: ' + ack.msg)
		exit(1)
	}
	println(ack.msg)
}

fn do_logs(rest []string) {
	mut proc := 'opencode'
	mut tailn := ''
	mut follow := false
	mut i := 0
	for i < rest.len {
		a := rest[i]
		if a == '-f' {
			follow = true
		} else if a == 'tail' {
			if i + 1 < rest.len {
				tailn = rest[i + 1]
				i++
			}
		} else if is_int(a) {
			tailn = a
		} else {
			proc = a
		}
		i++
	}
	cmd := Command{
		op:     'logs'
		target: proc
		arg:    tailn
		arg2:   if follow { 'follow' } else { '' }
	}
	fd := connect()
	defer { c_close(fd) }
	c_send_str(fd, json.encode(cmd) + '\n')
	if follow {
		for {
			line := c_recv_line(fd)
			if line.len == 0 {
				break
			}
			println(line)
		}
	} else {
		for {
			line := c_recv_line(fd)
			if line == '__END__' {
				break
			}
			if line.len == 0 {
				break
			}
			println(line)
		}
	}
}

fn do_version(args []string) {
	vm := vmod.decode(@VMOD_FILE) or {
		eprintln('oc: cannot read v.mod: ' + err.msg())
		exit(1)
	}
	mut target := ''
	if args.len > 2 {
		target = args[2]
	}
	resp := send_recv_one(Command{ op: 'version', target: target })
	ack := json.decode(AckResp, resp) or {
		eprintln('oc: bad response: ' + resp)
		exit(1)
	}
	println('oc version : ' + vm.version)
	if !ack.ok {
		eprintln('oc: ' + ack.msg)
		exit(1)
	}
	println(ack.msg)
	print_latest(target)
}

// LatestVer is one successfully fetched online version.
struct LatestVer {
	name string
	ver  string
}

// LatestReq describes one online version source.
// npm=false means a GitHub releases endpoint ({"tag_name": "vX.Y.Z"}),
// npm=true means an npm registry endpoint ({"version": "X.Y.Z"}).
struct LatestReq {
	name string
	url  string
	npm  bool
}

struct GhRelease {
	tag_name string
}

struct NpmRelease {
	version string
}

// latest_reqs returns the online sources matching the version target.
// Unknown targets never reach this: the daemon rejects them earlier.
fn latest_reqs(target string) []LatestReq {
	opencode :=
		LatestReq{'opencode', 'https://api.github.com/repos/anomalyco/opencode/releases/latest', false}
	openchamber :=
		LatestReq{'openchamber', 'https://registry.npmjs.org/@openchamber/web/latest', true}
	manage_oc :=
		LatestReq{'manage-oc', 'https://api.github.com/repos/evemarco/manage-oc/releases/latest', false}
	return match target {
		'opencode' { [opencode] }
		'openchamber' { [openchamber] }
		'ocd' { [manage_oc] }
		else { [opencode, openchamber, manage_oc] }
	}
}

// fetch_latest queries one source; returns '' on any failure (offline, timeout, bad payload).
fn fetch_latest(req LatestReq) string {
	resp := http.fetch(http.FetchConfig{
		url:          req.url
		read_timeout: 2 * time.second
		header:       http.new_header(key: .user_agent, value: 'oc-version-check')
	}) or { return '' }
	if resp.status_code != 200 {
		return ''
	}
	if req.npm {
		r := json.decode(NpmRelease, resp.body) or { return '' }
		return r.version
	}
	r := json.decode(GhRelease, resp.body) or { return '' }
	return r.tag_name.trim_left('v')
}

// fetch_and_send always delivers on the channel (empty ver on failure) so
// the collector below never blocks longer than the slowest HTTP timeout.
fn fetch_and_send(req LatestReq, ch chan LatestVer) {
	ch <- LatestVer{req.name, fetch_latest(req)}
}

// print_latest fetches online versions in parallel and prints them.
// Stays completely silent when offline or when every source fails.
fn print_latest(target string) {
	reqs := latest_reqs(target)
	ch := chan LatestVer{cap: reqs.len}
	for r in reqs {
		go fetch_and_send(r, ch)
	}
	mut found := map[string]string{}
	for _ in 0 .. reqs.len {
		lv := <-ch
		if lv.ver != '' {
			found[lv.name] = lv.ver
		}
	}
	if found.len == 0 {
		return
	}
	println('')
	println('latest (online)')
	for r in reqs {
		if r.name in found {
			println('  ' + pad(r.name, 12) + ': ' + found[r.name])
		}
	}
}

fn main() {
	args := os.args
	for a in args {
		if a == '--version' {
			vm := vmod.decode(@VMOD_FILE) or {
				eprintln('oc: cannot read v.mod: ' + err.msg())
				exit(1)
			}
			println('oc ' + vm.version)
			exit(0)
		}
	}
	if args.len < 2 {
		do_status()
		println('')
		println("Run 'oc help' for usage.")
		return
	}
	sub := args[1]
	match sub {
		'status' {
			do_status()
		}
		'cwd' {
			do_cwd(args[2..])
		}
		'restart' {
			do_simple('restart', args)
		}
		'stop' {
			do_simple('stop', args)
		}
		'start' {
			do_simple('start', args)
		}
		'logs' {
			do_logs(args[2..])
		}
		'reload' {
			do_simple('reload', args)
		}
		'version' {
			do_version(args)
		}
		'shutdown' {
			do_simple('shutdown', args)
		}
		'help', '--help', '-h' {
			usage(false)
		}
		else {
			eprintln('oc: unknown command: ' + sub)
			usage(true)
			exit(2)
		}
	}
}
