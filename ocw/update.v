module main

import json2
import net.http
import os
import semver
import time
import v.vmod

const manage_oc_release_api = 'https://api.github.com/repos/evemarco/manage-oc/releases/latest'
const manage_oc_release_download = 'https://github.com/evemarco/manage-oc/releases/download'
const managed_binaries = ['ocwd', 'ocw', 'procwd']!

struct ReleaseAsset {
	arch      string
	archive   string
	directory string
}

fn release_asset(os_name string, machine string) !ReleaseAsset {
	if os_name != 'Linux' {
		return error('unsupported operating system: ${os_name} (Linux is required)')
	}
	arch := match machine {
		'x86_64', 'amd64' { 'x64' }
		'aarch64', 'arm64' { 'arm64' }
		else { return error('unsupported CPU architecture: ${machine} (x86_64 or ARM64 is required)') }
	}

	directory := 'manage-oc-linux-${arch}'
	return ReleaseAsset{
		arch:      arch
		archive:   '${directory}.tar.gz'
		directory: directory
	}
}

fn release_is_newer(latest string, current string) !bool {
	latest_version := semver.from(latest)!
	current_version := semver.from(current)!
	return current_version < latest_version
}

fn parse_binary_version(name string, output string) string {
	fields := output.trim_space().fields()
	if fields.len != 2 || fields[0] != name {
		return ''
	}
	return fields[1]
}

fn configured_value(name string, fallback string) string {
	value := os.getenv(name)
	return if value == '' { fallback } else { value }
}

fn current_manage_oc_version() !string {
	vm := vmod.decode(@VMOD_FILE)!
	return vm.version
}

fn system_release_asset() !ReleaseAsset {
	os_result := os.execute('uname -s')
	if os_result.exit_code != 0 {
		return error('cannot detect operating system: ${os_result.output.trim_space()}')
	}
	arch_result := os.execute('uname -m')
	if arch_result.exit_code != 0 {
		return error('cannot detect CPU architecture: ${arch_result.output.trim_space()}')
	}
	return release_asset(os_result.output.trim_space(), arch_result.output.trim_space())
}

fn fetch_latest_manage_oc() !string {
	url := configured_value('MANAGE_OC_RELEASE_API_URL', manage_oc_release_api)
	resp := http.fetch(http.FetchConfig{
		url:          url
		read_timeout: 5 * time.second
		header:       http.new_header(key: .user_agent, value: 'ocw-release-check')
	})!
	if resp.status_code != 200 {
		return error('GitHub release check returned HTTP ${resp.status_code}')
	}
	release := json2.decode[GhRelease](resp.body)!
	if !release.tag_name.starts_with('v') {
		return error('latest release has an invalid tag: ${release.tag_name}')
	}
	version := release.tag_name[1..]
	semver.from(version)!
	return version
}

fn do_check() {
	asset := system_release_asset() or {
		eprintln('ocw: ${err.msg()}')
		exit(1)
	}
	current := current_manage_oc_version() or {
		eprintln('ocw: cannot read current version: ${err.msg()}')
		exit(1)
	}
	latest := fetch_latest_manage_oc() or {
		eprintln('ocw: cannot check latest release: ${err.msg()}')
		exit(1)
	}
	newer := release_is_newer(latest, current) or {
		eprintln('ocw: cannot compare releases: ${err.msg()}')
		exit(1)
	}
	println('platform : Linux/${asset.arch}')
	println('installed: ${current}')
	println('latest   : ${latest}')
	if newer {
		println('update available: ${latest} (run: ocw update)')
		return
	}
	if release_is_newer(current, latest) or { false } {
		println('installed version is newer than the latest release.')
		return
	}
	println('manage-oc is up to date.')
}

fn download_release(version string, asset ReleaseAsset, temporary_dir string) !string {
	base_url := configured_value('MANAGE_OC_RELEASE_DOWNLOAD_URL', manage_oc_release_download)
	url := '${base_url}/v${version}/${asset.archive}'
	println('Downloading ${asset.archive}...')
	resp := http.fetch(http.FetchConfig{
		url:          url
		read_timeout: 60 * time.second
		header:       http.new_header(key: .user_agent, value: 'ocw-update')
	})!
	if resp.status_code != 200 {
		return error('release download returned HTTP ${resp.status_code}')
	}
	archive := os.join_path(temporary_dir, asset.archive)
	os.write_file(archive, resp.body)!
	return archive
}

fn validate_release(version string, asset ReleaseAsset, temporary_dir string) ! {
	for name in managed_binaries {
		path := os.join_path(temporary_dir, asset.directory, name)
		if !os.is_file(path) {
			return error('release archive is missing ${name}')
		}
		result := os.execute('${os.quoted_path(path)} --version')
		if result.exit_code != 0 {
			return error('${name} cannot run on this Linux system: ${result.output.trim_space()}')
		}
		binary_version := parse_binary_version(name, result.output)
		if binary_version != version {
			return error('${name} version mismatch: expected ${version}, found ${binary_version}')
		}
	}
}

fn update_manage_oc() ! {
	asset := system_release_asset()!
	current := current_manage_oc_version()!
	latest := fetch_latest_manage_oc()!
	if !release_is_newer(latest, current)! {
		if release_is_newer(current, latest)! {
			println('Installed manage-oc ${current} is newer than the latest release ${latest}; nothing to do.')
		} else {
			println('manage-oc is already up to date (${current}).')
		}
		return
	}
	tools := discover_update_tools()!
	install_dir := configured_value('MANAGE_OC_INSTALL_DIR', '/usr/local/bin')
	installer := new_binary_installer(install_dir, tools)!
	temporary_dir := create_update_temp_dir(tools.mktemp_path)!
	defer {
		os.rmdir_all(temporary_dir) or {}
	}
	archive := download_release(latest, asset, temporary_dir)!
	extract_release(archive, temporary_dir, tools.tar_path)!
	validate_release(latest, asset, temporary_dir)!
	for name in managed_binaries {
		source := os.join_path(temporary_dir, asset.directory, name)
		installer.install(source, name)!
	}
	println('Installed manage-oc ${latest} in ${install_dir}.')
	println('Restart ocwd to run the updated daemon binary.')
}

fn do_update() {
	update_manage_oc() or {
		eprintln('ocw: update failed: ${err.msg()}')
		exit(1)
	}
}
