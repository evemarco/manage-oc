#!/bin/sh
set -eu

repo="evemarco/manage-oc"
install_dir="${MANAGE_OC_INSTALL_DIR:-/usr/local/bin}"
binaries="ocwd ocw procwd"

compile_from_source() {
	printf '%s\n' \
		"Please compile manage-oc from source instead:" \
		"https://github.com/${repo}#build--install" >&2
}

os_name=$(uname -s)
if [ "$os_name" != "Linux" ]; then
	printf 'Unsupported operating system: %s (Linux is required).\n' "$os_name" >&2
	compile_from_source
	exit 1
fi

cpu_arch=$(uname -m)
case "$cpu_arch" in
	x86_64 | amd64) release_arch='x64' ;;
	aarch64 | arm64) release_arch='arm64' ;;
	*)
		printf 'Unsupported CPU architecture: %s (x86_64 or ARM64 is required).\n' \
			"$cpu_arch" >&2
		compile_from_source
		exit 1
		;;
esac
asset_dir="manage-oc-linux-${release_arch}"
asset="${asset_dir}.tar.gz"

for command_name in curl tar sort head install mktemp; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		printf 'Required command not found: %s\n' "$command_name" >&2
		exit 1
	fi
done

printf 'Checking the latest manage-oc release...\n'
latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
	"https://github.com/${repo}/releases/latest")
latest_tag=${latest_url##*/}
case "$latest_tag" in
	v[0-9]*) ;;
	*)
		printf 'Could not determine the latest manage-oc release.\n' >&2
		exit 1
		;;
esac
latest_version=${latest_tag#v}

parse_version_output() {
	expected_name=$1
	version_output=$2
	set -- $version_output
	[ "$#" -eq 2 ] && [ "$1" = "$expected_name" ] || return 1
	printf '%s\n' "$2"
}

version_of() {
	binary_name=$1
	binary_path=$2
	version_output=$("$binary_path" --version 2>/dev/null) || return 1
	parse_version_output "$binary_name" "$version_output"
}

version_is_older() {
	current=$1
	latest=$2
	[ "$current" != "$latest" ] &&
		[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | head -n 1)" = "$current" ]
}

needs_install=0
for binary_name in $binaries; do
	binary_path="${install_dir}/${binary_name}"
	if [ ! -x "$binary_path" ]; then
		printf '%s: not installed\n' "$binary_name"
		needs_install=1
		continue
	fi
	if ! current_version=$(version_of "$binary_name" "$binary_path"); then
		printf '%s: installed version could not be read\n' "$binary_name"
		needs_install=1
		continue
	fi
	printf '%s: installed %s, latest %s\n' "$binary_name" "$current_version" "$latest_version"
	if version_is_older "$current_version" "$latest_version"; then
		needs_install=1
	fi
done

if [ "$needs_install" -eq 0 ]; then
	printf 'manage-oc is already up to date.\n'
	exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
	run_install=''
elif command -v sudo >/dev/null 2>&1; then
	run_install='sudo'
else
	printf 'Installing to %s requires root privileges or sudo.\n' "$install_dir" >&2
	exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
archive="${tmp_dir}/${asset}"
download_url="https://github.com/${repo}/releases/download/${latest_tag}/${asset}"

printf 'Downloading manage-oc %s...\n' "$latest_version"
curl -fsSL "$download_url" -o "$archive"
tar -xzf "$archive" -C "$tmp_dir"

for binary_name in $binaries; do
	source_path="${tmp_dir}/${asset_dir}/${binary_name}"
	if [ ! -f "$source_path" ]; then
		printf 'Release archive is missing %s.\n' "$binary_name" >&2
		exit 1
	fi
	if ! archive_output=$("$source_path" --version 2>&1); then
		printf 'The %s release binary cannot run on this Linux system:\n' "$binary_name" >&2
		printf '%s\n' "$archive_output" >&2
		compile_from_source
		exit 1
	fi
	if ! archive_version=$(parse_version_output "$binary_name" "$archive_output"); then
		printf 'The %s release binary returned an invalid version: %s\n' \
			"$binary_name" "$archive_output" >&2
		exit 1
	fi
	if [ "$archive_version" != "$latest_version" ]; then
		printf '%s version mismatch: expected %s, found %s.\n' \
			"$binary_name" "$latest_version" "$archive_version" >&2
		exit 1
	fi
done

if [ -n "$run_install" ]; then
	$run_install mkdir -p "$install_dir"
else
	mkdir -p "$install_dir"
fi

for binary_name in $binaries; do
	source_path="${tmp_dir}/${asset_dir}/${binary_name}"
	temporary_path="${install_dir}/.${binary_name}.tmp.$$"
	if [ -n "$run_install" ]; then
		$run_install install -m 0755 "$source_path" "$temporary_path"
		$run_install mv -f "$temporary_path" "${install_dir}/${binary_name}"
	else
		install -m 0755 "$source_path" "$temporary_path"
		mv -f "$temporary_path" "${install_dir}/${binary_name}"
	fi
done

printf 'Installed manage-oc %s in %s.\n' "$latest_version" "$install_dir"
