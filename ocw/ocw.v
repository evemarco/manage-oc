module main

import os
import v.vmod

fn usage(to_err bool) {
	lines := [
		'usage:',
		'  ocw status',
		'  ocw cwd [set [dir]] | <dir>',
		'  ocw restart [opencode|openchamber|all]',
		'  ocw stop    [opencode|openchamber|all]',
		'  ocw start   [opencode|openchamber|all]',
		'  ocw reload',
		'  ocw logs    [opencode|openchamber] [-f] [tail N]',
		'  ocw version [opencode|openchamber|ocwd|all]',
		'  ocw check',
		'  ocw update',
		'  ocw shutdown',
		'  ocw help',
	]
	for line in lines {
		if to_err {
			eprintln(line)
		} else {
			println(line)
		}
	}
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

fn pad(s string, n int) string {
	mut r := s
	for r.len < n {
		r += ' '
	}
	return r
}

fn main() {
	args := os.args
	for a in args {
		if a == '--version' {
			vm := vmod.decode(@VMOD_FILE) or {
				eprintln('ocw: cannot read v.mod: ' + err.msg())
				exit(1)
			}
			println('ocw ' + vm.version)
			exit(0)
		}
	}
	if args.len < 2 {
		do_status()
		println('')
		println("Run 'ocw help' for usage.")
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
		'check' {
			do_check()
		}
		'update' {
			do_update()
		}
		'shutdown' {
			do_simple('shutdown', args)
		}
		'help', '--help', '-h' {
			usage(false)
		}
		else {
			eprintln('ocw: unknown command: ' + sub)
			usage(true)
			exit(2)
		}
	}
}
