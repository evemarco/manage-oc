module main

fn test_release_asset_selects_x64_for_x86_64() {
	asset := release_asset('Linux', 'x86_64') or {
		assert false, err.msg()
		return
	}
	assert asset.arch == 'x64'
	assert asset.archive == 'manage-oc-linux-x64.tar.gz'
	assert asset.directory == 'manage-oc-linux-x64'
}

fn test_release_asset_selects_arm64_for_aarch64() {
	asset := release_asset('Linux', 'aarch64') or {
		assert false, err.msg()
		return
	}
	assert asset.arch == 'arm64'
	assert asset.archive == 'manage-oc-linux-arm64.tar.gz'
	assert asset.directory == 'manage-oc-linux-arm64'
}

fn test_release_is_newer_compares_semantic_versions() {
	assert release_is_newer('0.4.0', '0.3.9') or { false }
	assert !(release_is_newer('0.3.0', '0.3.0') or { true })
	assert !(release_is_newer('0.2.9', '0.3.0') or { true })
}

fn test_parse_binary_version_requires_expected_name() {
	assert parse_binary_version('ocw', 'ocw 0.4.0\n') == '0.4.0'
	assert parse_binary_version('ocw', 'ocwd 0.4.0\n') == ''
	assert parse_binary_version('ocw', 'ocw') == ''
}
