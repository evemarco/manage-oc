module main

import os
import json2
import v.vmod

fn do_status() {
	resp := send_recv_one(Command{ op: 'status' })
	st := json2.decode[StatusResp](resp) or {
		eprintln('ocw: bad response: ' + resp)
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
		ack := json2.decode[AckResp](resp) or {
			eprintln('ocw: bad response: ' + resp)
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
	ack := json2.decode[AckResp](resp) or {
		eprintln('ocw: bad response: ' + resp)
		exit(1)
	}
	if !ack.ok {
		eprintln('ocw: ' + ack.msg)
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
	ack := json2.decode[AckResp](resp) or {
		eprintln('ocw: bad response: ' + resp)
		exit(1)
	}
	if !ack.ok {
		eprintln('ocw: ' + ack.msg)
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
	c_send_str(fd, json2.encode(cmd) + '\n')
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
		eprintln('ocw: cannot read v.mod: ' + err.msg())
		exit(1)
	}
	mut target := ''
	if args.len > 2 {
		target = args[2]
	}
	resp := send_recv_one(Command{ op: 'version', target: target })
	ack := json2.decode[AckResp](resp) or {
		eprintln('ocw: bad response: ' + resp)
		exit(1)
	}
	println('ocw version : ' + vm.version)
	if !ack.ok {
		eprintln('ocw: ' + ack.msg)
		exit(1)
	}
	println(ack.msg)
	print_latest(target)
}
