import os
import strconv

fn is_pid(s string) bool {
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

fn resolve_pids(target string) []int {
	mut pids := []int{}
	if is_pid(target) {
		pid := strconv.atoi(target) or { return pids }
		return [pid]
	}
	procs := os.ls('/proc') or { return pids }
	for entry in procs {
		if !is_pid(entry) {
			continue
		}
		pid := strconv.atoi(entry) or { continue }
		comm := (os.read_file('/proc/' + entry + '/comm') or { '' }).trim_space()
		if comm == target {
			pids << pid
			continue
		}
		cmdline := os.read_file('/proc/' + entry + '/cmdline') or { '' }
		first := cmdline.split('\x00')[0].all_after_last('/')
		if first == target {
			pids << pid
		}
	}
	return pids
}

fn cwd_of(pid int) !string {
	link := '/proc/' + pid.str() + '/cwd'
	if !os.exists(link) {
		return error('no such process')
	}
	return os.readlink(link)
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: procd <pid|name> [pid|name...]')
		exit(2)
	}
	mut any_error := false
	for arg in os.args[1..] {
		pids := resolve_pids(arg)
		if pids.len == 0 {
			eprintln("procwd: no process matching '" + arg + "'")
			any_error = true
			continue
		}
		for pid in pids {
			cwd := cwd_of(pid) or {
				eprintln('procwd: ' + pid.str() + ': ' + err.msg())
				any_error = true
				continue
			}
			println(pid.str() + ': ' + cwd)
		}
	}
	if any_error {
		exit(1)
	}
}
