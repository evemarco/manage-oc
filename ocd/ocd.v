module main

import os
import net
import time
import json
import v.vmod

#include "globals.h"

// C-side accessors for the globals shared with the signal handler.
fn C.ocd_get_listen() int
fn C.ocd_set_listen(int)
fn C.ocd_get_pid(int) int
fn C.ocd_set_pid(int, int)
fn C.ocd_get_reload() int
fn C.ocd_set_reload(int)
fn C.ocd_get_foreground() int
fn C.ocd_set_foreground(int)

// ---- daemon runtime paths / constants ----
const o_rdwr = 2
const o_wronly = 1
const o_creat = 64
const o_append = 1024
const daemon_log = '/run/ocd/daemon.log'
const runtime_dir = '/run/ocd'
const pid_path = '/run/ocd/ocd.pid'
const state_path = '/run/ocd/state.json'
const logs_dir = '/run/ocd/logs'
const default_conf_path = '/etc/opencode-web.conf'
const opencode_bin = '/root/.opencode/bin/opencode'
const openchamber_bin = '/root/.local/share/pnpm/bin/openchamber'
const oc_host = '127.0.0.1'
const opencode_port = 4096
const openchamber_port = 4097

fn pid_alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return C.kill(pid, 0) == 0
}

// ---- conf / env / state ----
fn parse_conf(path string) map[string]string {
	mut m := map[string]string{}
	if !os.exists(path) {
		return m
	}
	lines := os.read_lines(path) or { return m }
	for line in lines {
		s := line.trim_space()
		if s.len == 0 || s.starts_with('#') || s.starts_with(';') {
			continue
		}
		idx := s.index_('=')
		if idx < 0 {
			continue
		}
		key := s[..idx].trim_space()
		val := s[idx + 1..].trim_space()
		if key.len > 0 {
			m[key] = val
		}
	}
	return m
}

fn build_env(conf map[string]string, is_opencode bool) map[string]string {
	mut env := os.environ()
	for k, v in conf {
		env[k] = v
	}
	if !is_opencode {
		env['OPENCODE_SKIP_START'] = 'true'
	}
	return env
}

struct ProcState {
	enabled bool = true
}

struct OcdState {
mut:
	cwd   string
	procs map[string]ProcState
}

fn default_state() OcdState {
	return OcdState{
		cwd:   '/root'
		procs: {
			'opencode':    ProcState{
				enabled: true
			}
			'openchamber': ProcState{
				enabled: true
			}
		}
	}
}

fn load_state() OcdState {
	mut st := default_state()
	if !os.exists(state_path) {
		return st
	}
	raw := os.read_file(state_path) or { return st }
	mut decoded := json.decode(OcdState, raw) or { return st }
	if decoded.cwd.len == 0 {
		decoded.cwd = '/root'
	}
	if 'opencode' !in decoded.procs {
		decoded.procs['opencode'] = ProcState{
			enabled: true
		}
	}
	if 'openchamber' !in decoded.procs {
		decoded.procs['openchamber'] = ProcState{
			enabled: true
		}
	}
	return decoded
}

fn save_state(st OcdState) {
	os.write_file(state_path, json.encode(st)) or {
		eprintln('ocd: cannot save state: ' + err.msg())
	}
}

// ---- port helpers ----
// port_free returns true when nothing is listening on (host, port).
fn port_free(host string, port int) bool {
	addr := '${host}:${port}'
	mut conn := net.dial_tcp(addr) or { return true }
	conn.close() or {}
	return false
}

// real cwd of a running pid via /proc/<pid>/cwd.
fn proc_cwd(pid int) string {
	if pid <= 0 {
		return ''
	}
	return os.readlink('/proc/${pid}/cwd') or { '' }
}

// ---- logging helpers (file based, no shared state) ----
fn log_path_for(name string) string {
	return logs_dir + '/' + name + '.log'
}

fn read_log_tail(path string, n int) []string {
	if !os.exists(path) {
		return []
	}
	lines := os.read_lines(path) or { return [] }
	if n <= 0 || n >= lines.len {
		return lines
	}
	return lines[lines.len - n..]
}

fn now_stamp() string {
	return time.now().format_ss()
}

fn append_log(mut f os.File, name string, chunk string) {
	stamp := now_stamp()
	for line in chunk.split('\n') {
		if line.len == 0 {
			continue
		}
		f.write_string('[${stamp}] [${name}] ${line}\n') or { return }
	}
	f.flush()
}

fn c_listen(path string) int {
	C.unlink(path.str)
	fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	if fd < 0 {
		return -1
	}
	unsafe {
		addr := &C.sockaddr_un{}
		C.memset(addr, 0, int(sizeof(C.sockaddr_un)))
		addr.sun_family = u16(C.AF_UNIX)
		C.strcpy(&addr.sun_path[0], path.str)
		if C.bind(fd, addr, int(sizeof(C.sockaddr_un))) != 0 {
			C.close(fd)
			return -1
		}
	}
	if C.listen(fd, 16) != 0 {
		C.close(fd)
		return -1
	}
	return fd
}

fn c_accept(listen_fd int) int {
	return C.accept(listen_fd, unsafe { nil }, unsafe { nil })
}

// redirect std fds: stdin -> /dev/null, and in background mode stdout/stderr -> daemon log file.
// In foreground mode stdout/stderr are left alone so logs go to the terminal,
// while log_msg() still writes a copy to daemon.log.
fn redirect_std_to_devnull(foreground bool) {
	unsafe {
		dn := C.open(&char(c'/dev/null'), o_rdwr, 0)
		if dn > 0 {
			C.dup2(dn, 0)
			C.close(dn)
		}
		if !foreground {
			lf := C.open(&char(daemon_log.str), o_wronly | o_creat | o_append, 0o644)
			if lf > 0 {
				C.dup2(lf, 1)
				C.dup2(lf, 2)
				C.close(lf)
			}
		}
	}
}

// log_msg writes to daemon.log and, in foreground mode, also prints to stderr.
fn log_msg(msg string) {
	if C.ocd_get_foreground() == 1 {
		eprintln(msg)
	}
	mut f := os.open_append(daemon_log) or { return }
	defer { f.close() }
	f.write_string('[${now_stamp()}] ${msg}\n') or { return }
}

@[heap]
struct Proc {
mut:
	name       string
	cmd        string
	args       []string
	is_oc      bool
	enabled    bool
	p          &os.Process
	have_proc  bool
	alive      bool
	started_at i64
	restarts   int
	backoff    int
	next_start i64
	logpath    string
}

struct Req {
	cmd   Command
	reply chan string
}

struct App {
mut:
	cwd       string
	conf_path string
	conf      map[string]string
	procs     map[string]&Proc
	listen_fd int
	shutting  bool
	req_chan  chan Req
	dead_chan chan DeathMsg
	tick_chan chan bool
}

// reported by a proc's log_pump when the process exits.
struct DeathMsg {
	name string
	pid  int
}

const daemonized_flag = '--__daemonized'

fn is_foreground_flag(s string) bool {
	return s == '--foreground' || s == '--no-daemon'
}

fn has_foreground_flag(args []string) bool {
	for a in args {
		if is_foreground_flag(a) {
			return true
		}
	}
	return false
}

fn has_daemonized_flag(args []string) bool {
	for a in args {
		if a == daemonized_flag {
			return true
		}
	}
	return false
}

fn has_reload_flag(args []string) bool {
	for a in args {
		if a == '--reload' {
			return true
		}
	}
	return false
}

fn do_reload() {
	if !os.exists(pid_path) {
		eprintln('ocd: not running (no pid file)')
		exit(1)
	}
	raw := os.read_file(pid_path) or { '' }
	pid := raw.trim_space().int()
	if pid <= 0 || C.kill(pid, 1) != 0 {
		eprintln('ocd: cannot signal daemon (pid ${pid})')
		exit(1)
	}
	println('ocd: reload signaled to daemon pid ${pid}')
	exit(0)
}

fn backoff_for(n int) int {
	return match n {
		1 { 1 }
		2 { 2 }
		3 { 4 }
		4 { 8 }
		5 { 16 }
		else { 30 }
	}
}

// ---------------- daemonization ----------------
fn daemonize(args []string) {
	exe := os.executable()
	mut sargs := ['--fork', exe, daemonized_flag]
	for i := 1; i < args.len; i++ {
		if is_foreground_flag(args[i]) || args[i] == daemonized_flag {
			continue
		}
		sargs << args[i]
	}
	mut p := os.new_process('setsid')
	p.set_args(sargs)
	p.set_environment(os.environ())
	p.run()
	// the original ocd process exits; setsid --fork launches the detached daemon.
	exit(0)
}

fn on_term(_sig os.Signal) {
	// kill the supervised process groups (use_pgroup => each proc is a group leader)
	for i := 0; i < 2; i++ {
		pid := C.ocd_get_pid(i)
		if pid > 0 {
			C.kill(-pid, 15)
		}
	}
	lfd := C.ocd_get_listen()
	if lfd >= 0 {
		C.close(lfd)
	}
	C.unlink(sock_path.str)
	C.unlink(pid_path.str)
	exit(0)
}

fn on_hup(_sig os.Signal) {
	C.ocd_set_reload(1)
}

// ---------------- supervisor ----------------
fn (mut app App) spawn_proc(name string) {
	mut pr := app.procs[name] or { return }
	if pr.have_proc {
		return
	}
	mut p := os.new_process(pr.cmd)
	p.set_args(pr.args)
	p.set_work_folder(app.cwd)
	p.set_environment(build_env(app.conf, pr.is_oc))
	p.set_redirect_stdio()
	p.use_pgroup = true
	p.run()
	pr.p = p
	pr.have_proc = true
	pr.alive = true
	pr.started_at = time.unix_now()
	pr.backoff = 0
	if pr.is_oc {
		C.ocd_set_pid(0, p.pid)
	} else {
		C.ocd_set_pid(1, p.pid)
	}
	log_msg('ocd: started ${name} (pid ${p.pid}) in ${app.cwd}')
	go app.log_pump(name)
}

fn (mut app App) restart_proc(name string) {
	mut pr := app.procs[name] or { return }
	pr.enabled = true
	pr.restarts = 0
	pr.backoff = 0
	pr.next_start = 0
	if pr.have_proc && pr.p.pid > 0 {
		pr.p.signal_pgkill()
	}
	// Do NOT set have_proc=false here: the death event from the log_pump
	// drives the respawn. Setting it false would let the tick spawn a
	// duplicate while this process is still releasing its port (crash loop).
}

fn (mut app App) stop_proc(pr &Proc) {
	if pr.have_proc {
		pr.p.signal_pgkill()
	}
}

fn (mut app App) tick() {
	if C.ocd_get_reload() == 1 {
		C.ocd_set_reload(0)
		app.cmd_reload()
		return
	}
	if app.shutting {
		return
	}
	now := time.unix_now()
	mut oc := app.procs['opencode'] or { return }
	mut och := app.procs['openchamber'] or { return }
	// ensure opencode
	if oc.enabled {
		if !oc.alive && !oc.have_proc && oc.next_start <= now {
			app.spawn_proc('opencode')
		}
	}
	// openchamber may only run once opencode is actually listening
	oc_listening := oc.alive && !port_free(oc_host, opencode_port)
	if och.enabled && oc_listening {
		if !och.alive && !och.have_proc && och.next_start <= now {
			app.spawn_proc('openchamber')
		}
	}
}

fn (mut app App) on_death(msg DeathMsg) {
	mut pr := app.procs[msg.name] or { return }
	// Ignore stale death reports from an older incarnation of this proc:
	// if we have already respawned (pr.p.pid changed), this event refers
	// to a previous process we no longer manage.
	if pr.p.pid != msg.pid {
		return
	}
	if !pr.enabled {
		pr.have_proc = false
		pr.alive = false
		return
	}
	pr.restarts++
	pr.backoff = backoff_for(pr.restarts)
	pr.next_start = time.unix_now() + i64(pr.backoff)
	pr.have_proc = false
	pr.alive = false
	if pr.is_oc {
		// opencode died -> stop openchamber (depends on opencode)
		app.stop_proc(app.procs['openchamber'] or { return })
	}
	log_msg('ocd: [${msg.name}] exited (restart #${pr.restarts}); backing off ${pr.backoff}s')
}

fn is_interpreter(cmd0 string) bool {
	base := cmd0.all_after_last('/').to_lower()
	return base in ['node', 'nodejs', 'python', 'python3', 'python2', 'ruby', 'perl', 'bun', 'deno']
}

fn running_version_of(pid int) string {
	cmdline := (os.read_file('/proc/${pid}/cmdline') or { '' }).split('\x00')
	if cmdline.len >= 2 && is_interpreter(cmdline[0]) {
		res := os.execute('/proc/${pid}/exe ${cmdline[1]} --version')
		if res.exit_code != 0 {
			return '(failed: exit ${res.exit_code})'
		}
		v := res.output.trim_space()
		if v == '' {
			return '(no output)'
		}
		return v
	}
	return binary_version('/proc/${pid}/exe')
}

fn find_pid_by_cmd(cmd string) int {
	target_real := os.real_path(cmd)
	base := cmd.all_after_last('/')
	entries := os.ls('/proc') or { return 0 }
	for entry in entries {
		if entry == '' {
			continue
		}
		mut is_num := true
		for ch in entry {
			if ch < `0` || ch > `9` {
				is_num = false
				break
			}
		}
		if !is_num {
			continue
		}
		pid := entry.int()
		if pid <= 1 {
			continue
		}
		cmdline := (os.read_file('/proc/${entry}/cmdline') or { '' }).split('\x00')
		for part in cmdline {
			if part == '' {
				continue
			}
			if target_real != '' && os.real_path(part) == target_real {
				return pid
			}
			if part.all_after_last('/') == base {
				return pid
			}
			if part.contains(base) {
				return pid
			}
		}
	}
	return 0
}

fn (app &App) adoption_watcher(name string, pid int) {
	for pid_alive(pid) {
		time.sleep(1 * time.second)
	}
	app.dead_chan <- DeathMsg{
		name: name
		pid:  pid
	}
}

fn (mut app App) adopt_existing_proc(name string) {
	mut pr := app.procs[name] or { return }
	if pr.have_proc || !pr.enabled {
		return
	}
	pid := find_pid_by_cmd(pr.cmd)
	if pid <= 0 {
		return
	}
	cmdline := (os.read_file('/proc/${pid}/cmdline') or { '' }).split('\x00')
	expected_port := if pr.is_oc { opencode_port.str() } else { openchamber_port.str() }
	mut has_port := false
	for part in cmdline {
		if part == expected_port {
			has_port = true
			break
		}
	}
	if !has_port {
		return
	}
	pr.alive = true
	pr.have_proc = true
	pr.p.pid = pid
	pr.started_at = time.unix_now()
	pr.backoff = 0
	pr.next_start = 0
	pr.restarts = 0
	if pr.is_oc {
		C.ocd_set_pid(0, pid)
	} else {
		C.ocd_set_pid(1, pid)
	}
	log_msg('ocd: adopted ${name} (pid ${pid})')
	go app.adoption_watcher(name, pid)
}

fn (mut app App) cmd_reload() {
	st := load_state()
	app.cwd = st.cwd
	app.conf = parse_conf(app.conf_path)
	for n in ['opencode', 'openchamber'] {
		mut pr := app.procs[n] or { continue }
		new_enabled := st.procs[n].enabled
		if pr.enabled != new_enabled {
			pr.enabled = new_enabled
			if !new_enabled {
				app.stop_proc(pr)
				pr.have_proc = false
				pr.alive = false
			} else if !pr.have_proc {
				pr.next_start = 0
			}
		}
		if new_enabled && !pr.have_proc {
			app.adopt_existing_proc(n)
		}
	}
	log_msg('ocd: reloaded state and configuration')
}

// ---------------- command handlers (run in supervisor goroutine) ----------------
fn (app App) cmd_status() string {
	mut procs := []ProcInfo{}
	for name in ['opencode', 'openchamber'] {
		pr := app.procs[name] or { continue }
		mut st := 'stopped'
		if pr.have_proc && pr.alive {
			st = 'running'
		} else if pr.have_proc && !pr.alive {
			st = 'crashed'
		}
		port := if pr.is_oc { opencode_port } else { openchamber_port }
		listening := !port_free(oc_host, port)
		mut pid := 0
		if pr.have_proc {
			pid = pr.p.pid
		}
		cwd := proc_cwd(pid)
		mut uptime := 0
		if pr.alive && pr.started_at > 0 {
			uptime = int(time.unix_now() - pr.started_at)
		}
		procs << ProcInfo{
			name:       name
			pid:        pid
			cwd:        cwd
			state:      st
			listening:  listening
			uptime_sec: uptime
			restarts:   pr.restarts
		}
	}
	return json.encode(StatusResp{ daemon_pid: os.getpid(), cwd: app.cwd, procs: procs })
}

fn binary_version(exe string) string {
	res := os.execute('${exe} --version')
	if res.exit_code != 0 {
		return '(failed: exit ${res.exit_code})'
	}
	v := res.output.trim_space()
	if v == '' {
		return '(no output)'
	}
	return v
}

fn daemon_version() string {
	vm := vmod.decode(@VMOD_FILE) or { return '(unknown)' }
	return vm.version
}

fn (app App) version_for_one(name string) string {
	pr := app.procs[name] or { return '${name} is not configured' }
	if !pr.have_proc || pr.p.pid <= 0 {
		return '${name} is not running'
	}
	if !pr.alive {
		return '${name} is not alive'
	}
	running_exe := os.readlink('/proc/${pr.p.pid}/exe') or { '' }
	if running_exe == '' {
		return '${name}: cannot read /proc/${pr.p.pid}/exe'
	}
	cmdline := (os.read_file('/proc/${pr.p.pid}/cmdline') or { '' }).split('\x00')
	is_interpreted := cmdline.len >= 2 && is_interpreter(cmdline[0])
	mut running_exe_display := running_exe
	if is_interpreted && cmdline.len >= 2 {
		running_exe_display = '${running_exe} ${cmdline[1]}'
	}
	disk_exe := pr.cmd
	running_exe_clean := running_exe.replace(' (deleted)', '').trim_space()
	is_deleted := running_exe.contains('(deleted)')

	running_version := running_version_of(pr.p.pid)
	disk_version := binary_version(disk_exe)
	mut interpreter_version := ''
	if is_interpreted {
		interpreter_version = binary_version('/proc/${pr.p.pid}/exe')
	}

	mut warnings := []string{}
	if is_deleted {
		warnings << 'running binary was deleted from disk'
	}
	if !is_interpreted && running_exe_clean != disk_exe {
		warnings << 'running binary path differs from configured path'
	}
	if running_version != disk_version && running_version != ''
		&& !running_version.starts_with('(failed') && !disk_version.starts_with('(failed') {
		warnings << 'running version differs from on-disk version'
	}

	mut msg := '${name} version\n'
	msg += '  running : ${running_version} (pid ${pr.p.pid})\n'
	msg += '  on disk : ${disk_version}\n'
	msg += '  running exe : ${running_exe_display}\n'
	msg += '  on disk exe : ${disk_exe}'
	if is_interpreted && interpreter_version != '' {
		msg += '\n  interpreter : ${interpreter_version}'
	}
	if warnings.len > 0 {
		msg += '\n  WARNING : ' + warnings.join('; ') + ' (restart recommended)'
	}
	return msg
}

fn (app App) cmd_version(target string) string {
	if target == 'ocd' {
		return json.encode(AckResp{ ok: true, msg: 'ocd version : ' + daemon_version() })
	}
	mut names := []string{}
	if target == '' || target == 'all' {
		names = ['opencode', 'openchamber']
	} else if target in app.procs {
		names = [target]
	} else {
		return json.encode(AckResp{ ok: false, msg: 'unknown target: ' + target })
	}
	mut lines := []string{}
	lines << 'ocd version : ' + daemon_version()
	for name in names {
		lines << app.version_for_one(name)
	}
	return json.encode(AckResp{ ok: true, msg: lines.join('\n') })
}

fn (mut app App) cmd_cwd_set(dir string) string {
	if dir == '' {
		return json.encode(AckResp{ ok: false, msg: 'no directory given' })
	}
	if !os.is_dir(dir) {
		return json.encode(AckResp{ ok: false, msg: 'not a directory: ' + dir })
	}
	app.cwd = os.real_path(dir)
	mut st := load_state()
	st.cwd = app.cwd
	save_state(st)
	app.restart_proc('opencode')
	app.restart_proc('openchamber')
	return json.encode(AckResp{ ok: true, msg: 'cwd set to ' + app.cwd + '; procs restarting' })
}

fn (mut app App) cmd_restart(target string) string {
	if target == 'all' || target == '' {
		app.restart_proc('opencode')
		app.restart_proc('openchamber')
		return json.encode(AckResp{ ok: true, msg: 'restarting all' })
	}
	if target in app.procs {
		app.restart_proc(target)
		return json.encode(AckResp{ ok: true, msg: 'restarting ' + target })
	}
	return json.encode(AckResp{ ok: false, msg: 'unknown target: ' + target })
}

fn (mut app App) cmd_set_enabled(target string, enable bool) string {
	mut names := []string{}
	if target == 'all' || target == '' {
		names = ['opencode', 'openchamber']
	} else if target in app.procs {
		names = [target]
	} else {
		return json.encode(AckResp{ ok: false, msg: 'unknown target: ' + target })
	}
	for n in names {
		mut pr := app.procs[n] or { continue }
		pr.enabled = enable
		if !enable {
			app.stop_proc(pr)
			pr.have_proc = false
			pr.alive = false
		}
	}
	verb := if enable { 'starting' } else { 'stopping' }
	return json.encode(AckResp{ ok: true, msg: verb + ' ' + names.join(', ') })
}

fn (mut app App) graceful_shutdown() {
	app.shutting = true
	for _, pr in app.procs {
		if pr.have_proc {
			pr.p.signal_pgkill()
		}
	}
	time.sleep(400 * time.millisecond)
	c_close(app.listen_fd)
	os.rm(pid_path) or {}
	os.rm(sock_path) or {}
	log_msg('ocd: shutdown complete')
}

fn (mut app App) handle_req(r Req) {
	mut resp := ''
	match r.cmd.op {
		'status' {
			resp = app.cmd_status()
		}
		'version' {
			resp = app.cmd_version(r.cmd.target)
		}
		'reload' {
			app.cmd_reload()
			resp = json.encode(AckResp{ ok: true, msg: 'reloaded state and configuration' })
		}
		'cwd' {
			if r.cmd.arg == 'set' {
				resp = app.cmd_cwd_set(r.cmd.target)
			} else {
				resp = json.encode(AckResp{ ok: true, msg: app.cwd })
			}
		}
		'restart' {
			resp = app.cmd_restart(r.cmd.target)
		}
		'stop' {
			resp = app.cmd_set_enabled(r.cmd.target, false)
		}
		'start' {
			resp = app.cmd_set_enabled(r.cmd.target, true)
		}
		'shutdown' {
			resp = json.encode(AckResp{ ok: true, msg: 'shutting down' })
			app.graceful_shutdown()
		}
		else {
			resp = json.encode(AckResp{ ok: false, msg: 'unknown op: ' + r.cmd.op })
		}
	}

	r.reply <- resp
}

// ---------------- log pump (one goroutine per spawned proc) ----------------
fn (app &App) log_pump(name string) {
	pr := app.procs[name] or { return }
	mut f := os.open_append(pr.logpath) or { return }
	defer { f.close() }
	mut p := pr.p
	watched := p.pid
	for p.is_alive() {
		mut did := false
		if p.is_pending(.stdout) {
			chunk := p.stdout_read()
			if chunk.len > 0 {
				append_log(mut f, name, chunk)
				did = true
			}
		}
		if p.is_pending(.stderr) {
			chunk := p.stderr_read()
			if chunk.len > 0 {
				append_log(mut f, name, chunk)
				did = true
			}
		}
		if !did {
			time.sleep(50 * time.millisecond)
		}
	}
	rem := p.stdout_slurp() + p.stderr_slurp()
	if rem.len > 0 {
		append_log(mut f, name, rem)
	}
	p.close()
	// notify the supervisor that this specific process exited
	app.dead_chan <- DeathMsg{
		name: name
		pid:  watched
	}
}

// ---------------- client connection handling ----------------
fn handle_logs(cmd Command, cfd int, stopping &bool) {
	path := log_path_for(cmd.target)
	if cmd.arg2 == 'follow' {
		if cmd.arg != '' {
			mut n := cmd.arg.int()
			if n <= 0 {
				n = 50
			}
			for line in read_log_tail(path, n) {
				c_send_str(cfd, line + '\n')
			}
		}
		follow_log(path, cfd, stopping)
	} else {
		mut n := 50
		if cmd.arg != '' {
			n = cmd.arg.int()
			if n <= 0 {
				n = 50
			}
		}
		for line in read_log_tail(path, n) {
			c_send_str(cfd, line + '\n')
		}
		c_send_str(cfd, '__END__\n')
	}
}

fn follow_log(path string, cfd int, stopping &bool) {
	mut off := 0
	if os.exists(path) {
		off = int(os.file_size(path))
	}
	for {
		if *stopping {
			break
		}
		if !os.exists(path) {
			time.sleep(200 * time.millisecond)
			continue
		}
		data := os.read_file(path) or {
			time.sleep(200 * time.millisecond)
			continue
		}
		if data.len > off {
			newpart := data[off..]
			if c_send_str(cfd, newpart) <= 0 {
				break
			}
			off = data.len
		}
		time.sleep(200 * time.millisecond)
	}
}

fn handle_client(app &App, cfd int) {
	line := c_recv_line(cfd)
	if line.len == 0 {
		c_close(cfd)
		return
	}
	cmd := json.decode(Command, line) or {
		c_send_str(cfd, json.encode(AckResp{ ok: false, msg: 'bad command' }) + '\n')
		c_close(cfd)
		return
	}
	if cmd.op == 'logs' {
		handle_logs(cmd, cfd, &app.shutting)
		c_close(cfd)
		return
	}
	req := Req{
		cmd:   cmd
		reply: chan string{cap: 1}
	}
	app.req_chan <- req
	resp := <-req.reply
	c_send_str(cfd, resp)
	c_close(cfd)
}

fn tick_loop(app &App) {
	for {
		if app.shutting {
			return
		}
		time.sleep(500 * time.millisecond)
		if app.shutting {
			return
		}
		app.tick_chan <- true
	}
}

fn accept_loop(app &App) {
	for {
		if app.shutting {
			break
		}
		cfd := c_accept(app.listen_fd)
		if cfd < 0 {
			if app.shutting {
				break
			}
			time.sleep(100 * time.millisecond)
			continue
		}
		go handle_client(app, cfd)
	}
}

fn (mut app App) run() {
	go tick_loop(app)
	go accept_loop(app)
	for {
		if app.shutting {
			break
		}
		select {
			r := <-app.req_chan {
				app.handle_req(r)
			}
			msg := <-app.dead_chan {
				app.on_death(msg)
			}
			_ := <-app.tick_chan {
				app.tick()
			}
		}
	}
}

// ---------------- entry point ----------------
fn run_daemon(args []string) {
	foreground := has_foreground_flag(args)
	C.ocd_set_foreground(if foreground { 1 } else { 0 })
	redirect_std_to_devnull(foreground)

	if os.exists(pid_path) {
		raw := os.read_file(pid_path) or { '' }
		pid := raw.trim_space().int()
		if pid_alive(pid) {
			eprintln('ocd: already running (pid ${pid})')
			exit(1)
		}
		os.rm(pid_path) or {}
	}

	os.mkdir_all(runtime_dir, os.MkdirParams{}) or {}
	os.mkdir_all(logs_dir, os.MkdirParams{}) or {}

	mut initial_cwd := ''
	mut conf_path := default_conf_path
	for i := 0; i < args.len; i++ {
		if args[i] == '--cwd' && i + 1 < args.len {
			initial_cwd = args[i + 1]
		}
		if (args[i] == '--config' || args[i] == '--env-file') && i + 1 < args.len {
			conf_path = args[i + 1]
		}
	}
	mut st := load_state()
	if initial_cwd != '' {
		if !os.is_dir(initial_cwd) {
			eprintln('ocd: --cwd is not a directory: ' + initial_cwd)
			exit(1)
		}
		st.cwd = os.real_path(initial_cwd)
		save_state(st)
	}

	os.write_file(pid_path, os.getpid().str()) or {
		eprintln('ocd: cannot write pidfile')
		exit(1)
	}

	os.signal_opt(.term, on_term) or {}
	os.signal_opt(.int, on_term) or {}
	os.signal_opt(.hup, on_hup) or {}

	lfd := c_listen(sock_path)
	if lfd < 0 {
		eprintln('ocd: cannot listen on ' + sock_path)
		os.rm(pid_path) or {}
		exit(1)
	}
	C.ocd_set_listen(lfd)

	mut app := &App{
		cwd:       st.cwd
		conf_path: conf_path
		conf:      parse_conf(conf_path)
		procs:     map[string]&Proc{}
		listen_fd: lfd
		req_chan:  chan Req{}
		dead_chan: chan DeathMsg{cap: 64}
		tick_chan: chan bool{cap: 4}
	}
	app.procs['opencode'] = &Proc{
		name:    'opencode'
		cmd:     opencode_bin
		args:    ['serve', '--port', opencode_port.str(), '--hostname', oc_host, '--print-logs']
		is_oc:   true
		enabled: st.procs['opencode'].enabled
		p:       &os.Process{}
		logpath: log_path_for('opencode')
	}
	app.procs['openchamber'] = &Proc{
		name:    'openchamber'
		cmd:     openchamber_bin
		args:    ['serve', '--foreground', '--port', openchamber_port.str(), '--host', oc_host]
		is_oc:   false
		enabled: st.procs['openchamber'].enabled
		p:       &os.Process{}
		logpath: log_path_for('openchamber')
	}

	app.adopt_existing_proc('opencode')
	app.adopt_existing_proc('openchamber')

	log_msg('ocd: daemon started pid ${os.getpid()}, cwd=${app.cwd}, socket=${sock_path}')
	app.run()
	exit(0)
}

fn usage() {
	eprintln('usage:')
	eprintln('  ocd [--foreground|--no-daemon] [--cwd <dir>] [--config <path>]')
	eprintln('  ocd --daemon')
	eprintln('  ocd --reload')
	eprintln('  ocd --version')
	eprintln('  ocd --help')
}

fn main() {
	args := os.args
	for a in args {
		if a == '--version' {
			vm := vmod.decode(@VMOD_FILE) or {
				eprintln('ocd: cannot read v.mod: ' + err.msg())
				exit(1)
			}
			println('ocd ' + vm.version)
			exit(0)
		}
		if a == '--help' || a == '-h' {
			usage()
			exit(0)
		}
	}
	if has_reload_flag(args) {
		do_reload()
		return
	}
	if has_foreground_flag(args) {
		run_daemon(args)
		return
	}
	if has_daemonized_flag(args) {
		run_daemon(args)
		return
	}
	daemonize(args)
}
