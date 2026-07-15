#!/bin/bash
# Install or remove the Waveshare IMX296 module on Jetson Nano.
set -euo pipefail

MODULE=imx296_waveshare
MODULE_DIR="/lib/modules/$(uname -r)/kernel/drivers/media/i2c"
AUTOLOAD=/etc/modules-load.d/imx296-waveshare.conf
BACKUP_DIR=/var/backups/imx296-waveshare
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
	cat <<EOF
Usage: sudo $0 [install|uninstall|status] [--reboot]

install    Install the .ko, load it now and enable it at boot (default)
uninstall  Remove it and restore the previously installed module, if any
status     Show installed files, module state and detected video nodes
--reboot   Reboot automatically after a successful install/uninstall
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

require_nano_r3275() {
	[[ $(uname -m) == aarch64 ]] || die "this package is for aarch64 Jetson Nano"
	[[ -r /etc/nv_tegra_release ]] || die "/etc/nv_tegra_release not found"
	grep -q 'R32.*REVISION: 7.5' /etc/nv_tegra_release || \
		die "L4T R32.7.5 is required: $(head -n1 /etc/nv_tegra_release)"
}

check_module_compatibility() {
	local vermagic
	vermagic=$(modinfo -F vermagic "$SCRIPT_DIR/$MODULE.ko")
	[[ $vermagic == "$(uname -r) "* || $vermagic == "$(uname -r)"* ]] || \
		die "module vermagic '$vermagic' does not match running kernel $(uname -r)"
}

install_driver() {
	require_nano_r3275
	[[ -s "$SCRIPT_DIR/$MODULE.ko" ]] || die "$SCRIPT_DIR/$MODULE.ko not found"
	check_module_compatibility

	mkdir -p "$BACKUP_DIR" "$MODULE_DIR"
	if [[ -e "$MODULE_DIR/$MODULE.ko" && ! -e "$BACKUP_DIR/$MODULE.ko" ]]; then
		cp -a "$MODULE_DIR/$MODULE.ko" "$BACKUP_DIR/$MODULE.ko"
	fi

	modprobe -r "$MODULE" 2>/dev/null || true
	install -m 0644 "$SCRIPT_DIR/$MODULE.ko" "$MODULE_DIR/$MODULE.ko"
	printf '%s\n' "$MODULE" > "$AUTOLOAD"
	depmod -a
	# Load the module immediately as well. The camera node itself appears after
	# reboot, when the newly installed DTB has taken effect.
	modprobe "$MODULE"
	sync

	echo "Installed and loaded $MODULE.ko; it will also load automatically at boot."
	echo "An IMX296 device-tree node must already be enabled for the camera to probe."
}

uninstall_driver() {
	require_nano_r3275
	modprobe -r "$MODULE" 2>/dev/null || true
	rm -f "$AUTOLOAD" "$MODULE_DIR/$MODULE.ko"
	if [[ -e "$BACKUP_DIR/$MODULE.ko" ]]; then
		cp -a "$BACKUP_DIR/$MODULE.ko" "$MODULE_DIR/$MODULE.ko"
	fi
	depmod -a
	sync
	echo "Waveshare module removed; any previous module was restored."
}

show_status() {
	echo "L4T: $(head -n1 /etc/nv_tegra_release 2>/dev/null || echo unknown)"
	echo "Kernel: $(uname -r)"
	if [[ -e "$MODULE_DIR/$MODULE.ko" ]]; then
		echo "Module file: $MODULE_DIR/$MODULE.ko"
	else
		echo "Module file: not installed"
	fi
	lsmod | awk -v module="$MODULE" 'NR == 1 || $1 == module'
	ls -l /dev/video* 2>/dev/null || true
	dmesg | grep -i -E 'imx296|nvcsi|tegra-capture-vi' | tail -30 || true
}

ACTION=install
REBOOT=0
for arg in "$@"; do
	case "$arg" in
	install|uninstall|status) ACTION=$arg ;;
	--reboot) REBOOT=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage; die "unknown argument: $arg" ;;
	esac
done

if [[ $ACTION != status && $EUID -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

case "$ACTION" in
	install) install_driver ;;
	uninstall) uninstall_driver ;;
	status) show_status ;;
esac

if [[ $REBOOT -eq 1 && $ACTION != status ]]; then
	reboot
fi
