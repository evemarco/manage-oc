module main

import json
import net.http
import time

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
		'ocwd' { [manage_oc] }
		else { [opencode, openchamber, manage_oc] }
	}
}

// fetch_latest queries one source; returns '' on any failure (offline, timeout, bad payload).
fn fetch_latest(req LatestReq) string {
	resp := http.fetch(http.FetchConfig{
		url:          req.url
		read_timeout: 2 * time.second
		header:       http.new_header(key: .user_agent, value: 'ocw-version-check')
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
