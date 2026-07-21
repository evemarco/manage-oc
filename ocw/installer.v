module main

import os

struct UpdateTools {
	tar_path     string
	mktemp_path  string
	install_path string
	mv_path      string
	mkdir_path   string
}

struct BinaryInstaller {
	directory string
	tools     UpdateTools
	sudo_path string
}

fn discover_update_tools() !UpdateTools {
	return UpdateTools{
		tar_path:     os.find_abs_path_of_executable('tar')!
		mktemp_path:  os.find_abs_path_of_executable('mktemp')!
		install_path: os.find_abs_path_of_executable('install')!
		mv_path:      os.find_abs_path_of_executable('mv')!
		mkdir_path:   os.find_abs_path_of_executable('mkdir')!
	}
}

fn new_binary_installer(directory string, tools UpdateTools) !BinaryInstaller {
	if os.getuid() == 0 || (os.exists(directory) && os.is_writable(directory)) {
		os.mkdir_all(directory)!
		return BinaryInstaller{
			directory: directory
			tools:     tools
		}
	}
	sudo_path := os.find_abs_path_of_executable('sudo') or {
		return error('installing to ${directory} requires root privileges or sudo')
	}
	result :=
		os.execute('${os.quoted_path(sudo_path)} ${os.quoted_path(tools.mkdir_path)} -p ${os.quoted_path(directory)}')
	if result.exit_code != 0 {
		return error('cannot create ${directory}: ${result.output.trim_space()}')
	}
	return BinaryInstaller{
		directory: directory
		tools:     tools
		sudo_path: sudo_path
	}
}

fn (installer BinaryInstaller) install(source string, name string) ! {
	temporary := os.join_path(installer.directory, '.${name}.tmp.${os.getpid()}')
	destination := os.join_path(installer.directory, name)
	prefix := if installer.sudo_path == '' { '' } else { '${os.quoted_path(installer.sudo_path)} ' }
	copy_result :=
		os.execute('${prefix}${os.quoted_path(installer.tools.install_path)} -m 0755 ${os.quoted_path(source)} ${os.quoted_path(temporary)}')
	if copy_result.exit_code != 0 {
		return error('cannot install ${name}: ${copy_result.output.trim_space()}')
	}
	move_result :=
		os.execute('${prefix}${os.quoted_path(installer.tools.mv_path)} -f ${os.quoted_path(temporary)} ${os.quoted_path(destination)}')
	if move_result.exit_code != 0 {
		return error('cannot activate ${name}: ${move_result.output.trim_space()}')
	}
}

fn create_update_temp_dir(mktemp_path string) !string {
	template := os.join_path(os.temp_dir(), 'ocw-update.XXXXXXXXXX')
	result := os.execute('${os.quoted_path(mktemp_path)} -d ${os.quoted_path(template)}')
	if result.exit_code != 0 {
		return error('cannot create private temporary directory: ${result.output.trim_space()}')
	}
	path := result.output.trim_space()
	if path == '' || !os.is_dir(path) {
		return error('mktemp did not create a temporary directory')
	}
	return path
}

fn extract_release(archive string, temporary_dir string, tar_path string) ! {
	result :=
		os.execute('${os.quoted_path(tar_path)} -xzf ${os.quoted_path(archive)} -C ${os.quoted_path(temporary_dir)}')
	if result.exit_code != 0 {
		return error('cannot extract release archive: ${result.output.trim_space()}')
	}
}
