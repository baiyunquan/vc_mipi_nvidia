#!/bin/bash
# ==============================================================================
# collect_support_info.sh
# Support information collection script for VC MIPI camera modules on
# NVIDIA Jetson / L4T platforms.
#
# Usage:
#   sudo ./collect_support_info.sh
#
# Output:
#   A timestamped tar.gz archive containing numbered text files with
#   system, hardware, driver, camera, and diagnostic information.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BASE_NAME="support_info_${TIMESTAMP}"
OUTPUT_DIR="$(pwd)/${BASE_NAME}"
ARCHIVE_PATH="$(pwd)/${BASE_NAME}.tar.gz"

# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

print_header() {
    echo ""
    echo "======================================================================"
    echo "  $1"
    echo "======================================================================"
    echo ""
}

write_header() {
    local file="$1"
    local title="$2"
    {
        echo "======================================================================"
        echo "  ${title}"
        echo "  Generated: $(date)"
        echo "  Host:      $(hostname)"
        echo "======================================================================"
        echo ""
    } >> "${file}"
}

write_section() {
    local file="$1"
    local title="$2"
    {
        echo ""
        echo "----------------------------------------------------------------------"
        echo "  ${title}"
        echo "----------------------------------------------------------------------"
        echo ""
    } >> "${file}"
}

run_cmd() {
    # run_cmd <output_file> <section_title> <command> [args...]
    local file="$1"
    local title="$2"
    shift 2
    local cmd="$1"

    write_section "${file}" "${title}"

    if command -v "${cmd}" > /dev/null 2>&1; then
        echo "  [CMD] $*"
        "$@" >> "${file}" 2>&1 || true
    else
        echo "  [SKIP] '${cmd}' not found, skipping: $*"
        echo "[SKIP] Command not found: ${cmd}" >> "${file}"
    fi
}

# ------------------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------------------

print_header "VC MIPI Support Info Collector -- NVIDIA Jetson / L4T"

if [[ "${EUID}" -ne 0 ]]; then
    echo "  ERROR: This script must be run as root."
    echo "         Please re-run with: sudo $0"
    exit 1
fi

echo "  Output directory : ${OUTPUT_DIR}"
echo "  Archive          : ${ARCHIVE_PATH}"
echo ""

mkdir -p "${OUTPUT_DIR}"

# ------------------------------------------------------------------------------
# 01 -- System Information
# ------------------------------------------------------------------------------
print_header "Collecting 01 -- System Information"
FILE="${OUTPUT_DIR}/01_system_info.txt"
write_header "${FILE}" "01 -- System Information"

run_cmd  "${FILE}" "Hostname"         hostname
run_cmd  "${FILE}" "Date / Time"      date
run_cmd  "${FILE}" "uname -a"         uname -a

write_section "${FILE}" "L4T Release (/etc/nv_tegra_release)"
if [[ -f /etc/nv_tegra_release ]]; then
    cat /etc/nv_tegra_release >> "${FILE}" 2>&1 || true
else
    echo "[INFO] /etc/nv_tegra_release not found" >> "${FILE}"
fi

write_section "${FILE}" "L4T Version (dpkg)"
dpkg -l 2>/dev/null | grep -i "nvidia-l4t-core\|libnvidia\|nv-tegra" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Jetson Model (/proc/device-tree/model)"
if [[ -f /proc/device-tree/model ]]; then
    printf '%s\n' "$(cat /proc/device-tree/model)" >> "${FILE}" 2>&1 || true
else
    echo "[INFO] /proc/device-tree/model not found" >> "${FILE}"
fi

write_section "${FILE}" "CUDA / nvcc Version"
if command -v nvcc > /dev/null 2>&1; then
    nvcc --version >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] nvcc not found" >> "${FILE}"
fi

write_section "${FILE}" "CUDA libraries (ldconfig)"
ldconfig -p 2>/dev/null | grep -i cuda >> "${FILE}" 2>&1 || true

run_cmd  "${FILE}" "CPU Info (/proc/cpuinfo)"     cat /proc/cpuinfo
run_cmd  "${FILE}" "Memory Info (/proc/meminfo)"  cat /proc/meminfo
run_cmd  "${FILE}" "Disk Usage (df -h)"           df -h
run_cmd  "${FILE}" "Uptime"                       uptime

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 02 -- Hardware Information
# ------------------------------------------------------------------------------
print_header "Collecting 02 -- Hardware Information"
FILE="${OUTPUT_DIR}/02_hardware_info.txt"
write_header "${FILE}" "02 -- Hardware Information"

write_section "${FILE}" "Tegra Chip ID"
if [[ -f /sys/module/tegra_fuse/parameters/tegra_chip_id ]]; then
    cat /sys/module/tegra_fuse/parameters/tegra_chip_id >> "${FILE}" 2>&1 || true
else
    CHIP_ID_FILE=$(find /sys/bus/platform/drivers/tegra-fuse -name "chip_id" 2>/dev/null | head -1 || true)
    if [[ -n "${CHIP_ID_FILE}" && -f "${CHIP_ID_FILE}" ]]; then
        cat "${CHIP_ID_FILE}" >> "${FILE}" 2>&1 || true
    else
        echo "[INFO] Tegra chip-id sysfs entry not found" >> "${FILE}"
    fi
fi

write_section "${FILE}" "Carrier Board EEPROM (i2c-0, address 0x57)"
if command -v i2cdump > /dev/null 2>&1; then
    i2cdump -y 0 0x57 >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] i2cdump not found. Install with: sudo apt-get install i2c-tools" >> "${FILE}"
fi

run_cmd  "${FILE}" "lspci"   lspci -vvv
run_cmd  "${FILE}" "lsusb"   lsusb -v

write_section "${FILE}" "Device Tree top-level nodes (/proc/device-tree)"
if [[ -d /proc/device-tree ]]; then
    ls -la /proc/device-tree/ >> "${FILE}" 2>&1 || true
else
    echo "[INFO] /proc/device-tree not found" >> "${FILE}"
fi

write_section "${FILE}" "Board Serial Number (/sys/firmware/devicetree/base/serial-number)"
if [[ -f /sys/firmware/devicetree/base/serial-number ]]; then
    printf '%s\n' "$(cat /sys/firmware/devicetree/base/serial-number)" >> "${FILE}" 2>&1 || true
else
    echo "[INFO] serial-number node not found" >> "${FILE}"
fi

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 03 -- Device Tree
# ------------------------------------------------------------------------------
print_header "Collecting 03 -- Device Tree"
FILE="${OUTPUT_DIR}/03_device_tree.txt"
write_header "${FILE}" "03 -- Device Tree"

# Auto-install dtc if missing and running as root
if ! command -v dtc > /dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
        echo "  [INFO] dtc not found, attempting to install device-tree-compiler..."
        apt-get install -y device-tree-compiler >> "${FILE}" 2>&1 || true
    else
        echo "  [WARN] dtc not found and not running as root -- cannot auto-install."
        echo "[WARN] dtc not found. Install with: sudo apt-get install device-tree-compiler" >> "${FILE}"
    fi
fi

write_section "${FILE}" "dtc version"
if command -v dtc > /dev/null 2>&1; then
    dtc --version >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] dtc not available" >> "${FILE}"
fi

write_section "${FILE}" "Decompiled Active Device Tree (dtc -I fs /sys/firmware/devicetree/base)"
if command -v dtc > /dev/null 2>&1; then
    if [[ -d /sys/firmware/devicetree/base ]]; then
        echo "  [CMD] dtc -s -I fs /sys/firmware/devicetree/base -O dts"
        dtc -s -I fs /sys/firmware/devicetree/base -O dts >> "${FILE}" 2>&1 || true
    else
        echo "[INFO] /sys/firmware/devicetree/base not found" >> "${FILE}"
    fi
else
    echo "[SKIP] dtc not available" >> "${FILE}"
fi

write_section "${FILE}" "VC MIPI / Camera / CSI Nodes (grep in decompiled DT)"
if command -v dtc > /dev/null 2>&1 && [[ -d /sys/firmware/devicetree/base ]]; then
    echo "  [CMD] dtc -s ... | grep -i -A5 'vc_mipi|vc-mipi|csi|camera|sensor|imx|ov'"
    dtc -s -I fs /sys/firmware/devicetree/base -O dts 2>/dev/null \
        | grep -i -A5 'vc_mipi\|vc-mipi\|csi\|camera\|sensor\|imx\|ov' \
        >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] dtc not available or DT base not found" >> "${FILE}"
fi

write_section "${FILE}" "Compatible strings in device tree (camera/sensor related)"
if [[ -d /sys/firmware/devicetree/base ]]; then
    find /sys/firmware/devicetree/base -name "compatible" 2>/dev/null | while read -r f; do
        val=$(cat "${f}" 2>/dev/null | tr '\0' '\n' || true)
        if echo "${val}" | grep -qi 'camera\|sensor\|csi\|mipi\|imx\|ov\|ar\|vc'; then
            echo "${f}: ${val}"
        fi
    done >> "${FILE}" 2>&1 || true
fi

write_section "${FILE}" "extlinux.conf"
for conf in /boot/extlinux/extlinux.conf /boot/extlinux.conf; do
    if [[ -f "${conf}" ]]; then
        echo "=== ${conf} ===" >> "${FILE}"
        cat "${conf}" >> "${FILE}" 2>&1 || true
        echo "" >> "${FILE}"
    fi
done
ls /boot/extlinux/extlinux.conf /boot/extlinux.conf > /dev/null 2>&1 \
    || echo "[INFO] No extlinux.conf found" >> "${FILE}"

write_section "${FILE}" "DTB files in /boot"
find /boot -name "*.dtb" -o -name "*.dtbo" 2>/dev/null | sort >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Applied Device Tree Overlays (/sys/kernel/config/device-tree/overlays)"
if [[ -d /sys/kernel/config/device-tree/overlays ]]; then
    ls -la /sys/kernel/config/device-tree/overlays/ >> "${FILE}" 2>&1 || true
    for overlay_dir in /sys/kernel/config/device-tree/overlays/*/; do
        if [[ -d "${overlay_dir}" ]]; then
            echo "Overlay: ${overlay_dir}" >> "${FILE}"
            ls -la "${overlay_dir}" >> "${FILE}" 2>&1 || true
        fi
    done
else
    echo "[INFO] /sys/kernel/config/device-tree/overlays not found" >> "${FILE}"
fi

write_section "${FILE}" "FDT / Overlay entries from extlinux.conf"
grep -hi "fdt\|overlay\|dtbo" \
    /boot/extlinux/extlinux.conf /boot/extlinux.conf 2>/dev/null \
    >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 04 -- Kernel & Driver Information
# ------------------------------------------------------------------------------
print_header "Collecting 04 -- Kernel & Driver Information"
FILE="${OUTPUT_DIR}/04_kernel_driver_info.txt"
write_header "${FILE}" "04 -- Kernel & Driver Information"

write_section "${FILE}" "Loaded Modules filtered for vc_mipi / v4l / camera / tegra"
lsmod 2>/dev/null | grep -i "vc_mipi\|v4l\|video\|camera\|tegra\|nvcsi\|host1x\|i2c" \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Full lsmod"
lsmod >> "${FILE}" 2>&1 || true

write_section "${FILE}" "dmesg -- VC MIPI messages"
dmesg 2>/dev/null | grep -i "vc_mipi\|vc-mipi" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "dmesg -- CSI messages"
dmesg 2>/dev/null | grep -i "csi\|nvcsi" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "dmesg -- I2C messages"
dmesg 2>/dev/null | grep -i "i2c" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "dmesg -- Camera / V4L2 messages"
dmesg 2>/dev/null | grep -i "camera\|v4l2\|video\|sensor\|imx\|ov[0-9]" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "dmesg -- Error / Warning messages (last 200)"
dmesg 2>/dev/null | grep -i "error\|warn\|fail\|timeout" | tail -200 >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Full dmesg"
dmesg >> "${FILE}" 2>&1 || true

write_section "${FILE}" "modinfo -- vc_mipi modules"
for mod in vc_mipi_core vc_mipi_camera vc_mipi; do
    if modinfo "${mod}" > /dev/null 2>&1; then
        echo "=== modinfo ${mod} ===" >> "${FILE}"
        modinfo "${mod}" >> "${FILE}" 2>&1 || true
        echo "" >> "${FILE}"
    fi
done
find "/lib/modules/$(uname -r)" -name "*vc_mipi*" -o -name "*vc-mipi*" 2>/dev/null \
    | while read -r ko; do
        echo "=== modinfo ${ko} ===" >> "${FILE}"
        modinfo "${ko}" >> "${FILE}" 2>&1 || true
        echo "" >> "${FILE}"
    done

write_section "${FILE}" "Kernel Config -- Camera / V4L2 / CSI options"
if [[ -f /proc/config.gz ]]; then
    zcat /proc/config.gz 2>/dev/null
elif [[ -f "/boot/config-$(uname -r)" ]]; then
    cat "/boot/config-$(uname -r)" 2>/dev/null
elif [[ -f /boot/config ]]; then
    cat /boot/config 2>/dev/null
else
    echo "[INFO] Kernel config not found at /proc/config.gz or /boot/config-$(uname -r)" \
        >> "${FILE}"
    false
fi | grep -iE "V4L|VIDEO|CAMERA|CSI|MIPI|MEDIA|TEGRA|I2C_MUX|IMX|OV[0-9]" \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Driver sysfs -- camera/csi related platform drivers"
ls /sys/bus/platform/drivers/ 2>/dev/null \
    | grep -i "camera\|csi\|tegra\|vi\|nvcsi\|host1x\|vc" \
    >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 05 -- Camera & V4L2 Information
# ------------------------------------------------------------------------------
print_header "Collecting 05 -- Camera & V4L2 Information"
FILE="${OUTPUT_DIR}/05_camera_v4l2_info.txt"
write_header "${FILE}" "05 -- Camera & V4L2 Information"

write_section "${FILE}" "Video devices (/dev/video*)"
ls -la /dev/video* 2>/dev/null >> "${FILE}" 2>&1 \
    || echo "[INFO] No /dev/video* devices found" >> "${FILE}"

write_section "${FILE}" "Media devices (/dev/media*)"
ls -la /dev/media* 2>/dev/null >> "${FILE}" 2>&1 \
    || echo "[INFO] No /dev/media* devices found" >> "${FILE}"

write_section "${FILE}" "V4L2 subdevices (/dev/v4l-subdev*)"
ls -la /dev/v4l-subdev* 2>/dev/null >> "${FILE}" 2>&1 \
    || echo "[INFO] No /dev/v4l-subdev* devices found" >> "${FILE}"

if command -v v4l2-ctl > /dev/null 2>&1; then
    write_section "${FILE}" "v4l2-ctl --list-devices"
    v4l2-ctl --list-devices >> "${FILE}" 2>&1 || true

    write_section "${FILE}" "Per-device: v4l2-ctl --all"
    for dev in /dev/video*; do
        if [[ -c "${dev}" ]]; then
            echo "=== ${dev} ===" >> "${FILE}"
            v4l2-ctl -d "${dev}" --all >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done

    write_section "${FILE}" "Per-device: v4l2-ctl --list-formats-ext"
    for dev in /dev/video*; do
        if [[ -c "${dev}" ]]; then
            echo "=== ${dev} ===" >> "${FILE}"
            v4l2-ctl -d "${dev}" --list-formats-ext >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done

    write_section "${FILE}" "Per-subdev: v4l2-ctl --all"
    for subdev in /dev/v4l-subdev*; do
        if [[ -c "${subdev}" ]]; then
            echo "=== ${subdev} ===" >> "${FILE}"
            v4l2-ctl -d "${subdev}" --all >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done
else
    write_section "${FILE}" "v4l2-ctl"
    echo "[SKIP] v4l2-ctl not found. Install with: sudo apt-get install v4l-utils" >> "${FILE}"
fi

if command -v media-ctl > /dev/null 2>&1; then
    write_section "${FILE}" "media-ctl --print-topology"
    for dev in /dev/media*; do
        if [[ -c "${dev}" ]]; then
            echo "=== ${dev} ===" >> "${FILE}"
            media-ctl -d "${dev}" --print-topology >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done
else
    write_section "${FILE}" "media-ctl"
    echo "[SKIP] media-ctl not found. Install with: sudo apt-get install v4l-utils" >> "${FILE}"
fi

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 06 -- I2C Information
# ------------------------------------------------------------------------------
print_header "Collecting 06 -- I2C Information"
FILE="${OUTPUT_DIR}/06_i2c_info.txt"
write_header "${FILE}" "06 -- I2C Information"

if command -v i2cdetect > /dev/null 2>&1; then
    run_cmd "${FILE}" "I2C adapters (i2cdetect -l)" i2cdetect -l

    write_section "${FILE}" "I2C bus scan (all buses)"
    i2cdetect -l 2>/dev/null | awk '{print $1}' | sed 's/i2c-//' | while read -r bus; do
        if [[ "${bus}" =~ ^[0-9]+$ ]]; then
            echo "=== Scanning I2C bus ${bus} ===" >> "${FILE}"
            i2cdetect -y -r "${bus}" >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done
else
    write_section "${FILE}" "i2cdetect"
    echo "[SKIP] i2cdetect not found. Install with: sudo apt-get install i2c-tools" >> "${FILE}"
fi

write_section "${FILE}" "I2C devices in sysfs (/sys/bus/i2c/devices)"
if [[ -d /sys/bus/i2c/devices ]]; then
    ls -la /sys/bus/i2c/devices/ >> "${FILE}" 2>&1 || true
    echo "" >> "${FILE}"
    for dev in /sys/bus/i2c/devices/*/; do
        if [[ -d "${dev}" ]]; then
            devname=""
            drivername=""
            [[ -f "${dev}name" ]] && devname=$(cat "${dev}name" 2>/dev/null || true)
            [[ -L "${dev}driver" ]] && drivername=$(basename "$(readlink "${dev}driver" 2>/dev/null)" || true)
            echo "  ${dev} | name=${devname} | driver=${drivername}" >> "${FILE}"
        fi
    done
else
    echo "[INFO] /sys/bus/i2c/devices not found" >> "${FILE}"
fi

write_section "${FILE}" "I2C MUX channel devices"
find /sys/bus/i2c/devices -name "channel-*" 2>/dev/null >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 07 -- VC MIPI Specific Information
# ------------------------------------------------------------------------------
print_header "Collecting 07 -- VC MIPI Specific Information"
FILE="${OUTPUT_DIR}/07_vc_mipi_specific.txt"
write_header "${FILE}" "07 -- VC MIPI Specific Information"

write_section "${FILE}" "VC MIPI sysfs entries"
find /sys -name "*vc_mipi*" -o -name "*vc-mipi*" 2>/dev/null >> "${FILE}" 2>&1 || true

write_section "${FILE}" "VC MIPI proc entries"
find /proc -name "*vc_mipi*" -o -name "*vc-mipi*" 2>/dev/null >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Device Tree compatible strings -- VC MIPI"
if [[ -d /sys/firmware/devicetree/base ]]; then
    find /sys/firmware/devicetree/base -name "compatible" 2>/dev/null | while read -r f; do
        val=$(cat "${f}" 2>/dev/null | tr '\0' '\n' || true)
        if echo "${val}" | grep -qi 'vc.mipi\|vc_mipi'; then
            echo "${f}:"
            echo "${val}"
            echo ""
        fi
    done >> "${FILE}" 2>&1 || true
fi

write_section "${FILE}" "dmesg -- All VC MIPI messages"
dmesg 2>/dev/null | grep -i "vc.mipi\|vc_mipi" >> "${FILE}" 2>&1 || true

write_section "${FILE}" "VC MIPI kernel module parameters"
for mod_path in /sys/module/vc_mipi_core /sys/module/vc_mipi_camera /sys/module/vc_mipi; do
    if [[ -d "${mod_path}" ]]; then
        echo "=== ${mod_path} ===" >> "${FILE}"
        if [[ -d "${mod_path}/parameters" ]]; then
            for param in "${mod_path}/parameters/"*; do
                [[ -f "${param}" ]] && \
                    echo "  $(basename "${param}") = $(cat "${param}" 2>/dev/null || true)" \
                    >> "${FILE}"
            done
        fi
        echo "" >> "${FILE}"
    fi
done

write_section "${FILE}" "VC MIPI module files on disk"
find "/lib/modules/$(uname -r)" -iname "*vc_mipi*" -o -iname "*vc-mipi*" 2>/dev/null \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "CSI / VI / Camera platform devices (sysfs)"
find /sys/devices -maxdepth 6 \( \
    -name "*nvcsi*" -o -name "*tegra-vi*" -o -name "*tegra-camera*" \
    -o -name "*host1x*" \) 2>/dev/null | head -60 >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Camera platform driver bindings"
find /sys/bus/platform/drivers -maxdepth 1 2>/dev/null | \
    grep -i "csi\|vi\|nvcsi\|camera\|vc" >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 08 -- Package Information
# ------------------------------------------------------------------------------
print_header "Collecting 08 -- Package Information"
FILE="${OUTPUT_DIR}/08_package_info.txt"
write_header "${FILE}" "08 -- Package Information"

write_section "${FILE}" "Installed packages -- camera / v4l / tegra / cuda / gstreamer"
dpkg -l 2>/dev/null | grep -i \
    "camera\|v4l\|video4linux\|tegra\|cuda\|gstreamer\|libav\|libvideo\|nvenc\|nvdec\|argus\|nvargus" \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "All NVIDIA / L4T packages"
dpkg -l 2>/dev/null | grep -i "nvidia\|nv-\|l4t\|libdrm\|libgles\|libegl" \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "v4l-utils version"
if command -v v4l2-ctl > /dev/null 2>&1; then
    v4l2-ctl --version >> "${FILE}" 2>&1 || true
fi
dpkg -l v4l-utils 2>/dev/null >> "${FILE}" 2>&1 || true

write_section "${FILE}" "GStreamer plugins -- camera/video/nvidia elements"
if command -v gst-inspect-1.0 > /dev/null 2>&1; then
    gst-inspect-1.0 2>/dev/null \
        | grep -i "camera\|v4l\|nvarg\|nvenc\|nvdec\|csi\|tegra" \
        >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] gst-inspect-1.0 not found" >> "${FILE}"
fi

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 09 -- Jetson Specific Information
# ------------------------------------------------------------------------------
print_header "Collecting 09 -- Jetson Specific Information"
FILE="${OUTPUT_DIR}/09_jetson_specific.txt"
write_header "${FILE}" "09 -- Jetson Specific Information"

write_section "${FILE}" "jetson_release"
if command -v jetson_release > /dev/null 2>&1; then
    jetson_release >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] jetson_release not found" >> "${FILE}"
fi

write_section "${FILE}" "nvpmodel (current power mode)"
if command -v nvpmodel > /dev/null 2>&1; then
    nvpmodel -q >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] nvpmodel not found" >> "${FILE}"
fi

write_section "${FILE}" "jetson_clocks --show"
if command -v jetson_clocks > /dev/null 2>&1; then
    jetson_clocks --show >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] jetson_clocks not found" >> "${FILE}"
fi

write_section "${FILE}" "Thermal zones (/sys/class/thermal)"
if [[ -d /sys/class/thermal ]]; then
    for tz in /sys/class/thermal/thermal_zone*/; do
        if [[ -d "${tz}" ]]; then
            name=""
            temp=""
            [[ -f "${tz}type" ]] && name=$(cat "${tz}type" 2>/dev/null || true)
            [[ -f "${tz}temp" ]] && temp=$(cat "${tz}temp" 2>/dev/null || true)
            printf '  %-20s type=%-30s temp=%s (millidegrees C)\n' \
                "$(basename "${tz}")" "${name}" "${temp}" >> "${FILE}"
        fi
    done
else
    echo "[INFO] /sys/class/thermal not found" >> "${FILE}"
fi

write_section "${FILE}" "nvidia-smi"
if command -v nvidia-smi > /dev/null 2>&1; then
    nvidia-smi >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] nvidia-smi not found" >> "${FILE}"
fi

write_section "${FILE}" "tegrastats (3-second sample)"
if command -v tegrastats > /dev/null 2>&1; then
    timeout 3 tegrastats >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] tegrastats not found" >> "${FILE}"
fi

write_section "${FILE}" "nvargus-daemon service status"
if command -v systemctl > /dev/null 2>&1; then
    systemctl status nvargus-daemon >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] systemctl not found" >> "${FILE}"
fi

write_section "${FILE}" "Multimedia API / Argus packages"
dpkg -l 2>/dev/null | grep -i "libargus\|nv-multimedia\|jetson-multimedia" \
    >> "${FILE}" 2>&1 || true

write_section "${FILE}" "Jetson platform config files"
for f in /etc/nv_tegra_release /etc/nv_boot_control.conf /etc/nvpmodel.conf; do
    if [[ -f "${f}" ]]; then
        echo "=== ${f} ===" >> "${FILE}"
        cat "${f}" >> "${FILE}" 2>&1 || true
        echo "" >> "${FILE}"
    else
        echo "[INFO] ${f} not found" >> "${FILE}"
    fi
done

write_section "${FILE}" "Storage / Boot partition layout"
if command -v lsblk > /dev/null 2>&1; then
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE >> "${FILE}" 2>&1 || true
fi
if command -v fdisk > /dev/null 2>&1; then
    fdisk -l >> "${FILE}" 2>&1 || true
fi

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 10 -- nvargus_nvraw tool (Argus Bayer Raw CLI)
# Ref: https://docs.nvidia.com/jetson/archives/r36.2/DeveloperGuide/SD/CameraDevelopment/ArgusNvrawTool.html
# ------------------------------------------------------------------------------
print_header "Collecting 10 -- nvargus_nvraw tool"
FILE="${OUTPUT_DIR}/10_nvargus_nvraw.txt"
write_header "${FILE}" "10 -- nvargus_nvraw tool (Argus Bayer Raw CLI)"

# Locate the nvargus_nvraw binary
NVRAW_BIN=""
for candidate in /usr/bin/nvargus_nvraw /usr/local/bin/nvargus_nvraw \
                 /opt/nvidia/bin/nvargus_nvraw; do
    if [[ -x "${candidate}" ]]; then
        NVRAW_BIN="${candidate}"
        break
    fi
done
if [[ -z "${NVRAW_BIN}" ]]; then
    NVRAW_BIN=$(find /usr /opt -name 'nvargus_nvraw' -type f -executable 2>/dev/null | head -1 || true)
fi

write_section "${FILE}" "nvargus_nvraw binary"
if [[ -n "${NVRAW_BIN}" ]]; then
    echo "Found: ${NVRAW_BIN}" >> "${FILE}"
    ls -la "${NVRAW_BIN}" >> "${FILE}" 2>&1 || true
else
    echo "[WARN] nvargus_nvraw not found in PATH or common locations." >> "${FILE}"
    echo "       On JetPack it is part of the Multimedia API samples." >> "${FILE}"
    echo "       Build location: /usr/src/jetson_multimedia_api/argus/samples/nvraw/" >> "${FILE}"
fi

write_section "${FILE}" "nvargus_nvraw --help"
if [[ -n "${NVRAW_BIN}" ]]; then
    echo "  [CMD] ${NVRAW_BIN} --help"
    timeout 10 "${NVRAW_BIN}" --help >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] nvargus_nvraw not available" >> "${FILE}"
fi

write_section "${FILE}" "nvargus_nvraw --sensorinfo (sensor list and exposure modes)"
# --sensorinfo lists all sensors detected by Argus, their index, name,
# active array size, and available exposure modes (HDR etc.)
# Requires nvargus-daemon to be running.
if [[ -n "${NVRAW_BIN}" ]]; then
    echo "  [CMD] ${NVRAW_BIN} --sensorinfo"
    # nvargus-daemon must be running; start it briefly if needed
    DAEMON_STARTED=0
    DAEMON_PID=""
    cleanup_daemon() {
        if [[ "${DAEMON_STARTED}" -eq 1 && -n "${DAEMON_PID}" ]]; then
            kill "${DAEMON_PID}" 2>/dev/null || true
            wait "${DAEMON_PID}" 2>/dev/null || true
        fi
    }
    trap 'cleanup_daemon' EXIT

    if ! pgrep -x nvargus-daemon > /dev/null 2>&1; then
        echo "  [INFO] nvargus-daemon not running, attempting to start temporarily..."
        nvargus-daemon &
        DAEMON_PID=$!
        DAEMON_STARTED=1
        sleep 2
    fi

    timeout 30 "${NVRAW_BIN}" --sensorinfo >> "${FILE}" 2>&1 || true

    cleanup_daemon
    DAEMON_STARTED=0
    trap - EXIT
else
    echo "[SKIP] nvargus_nvraw not available" >> "${FILE}"
    echo "" >> "${FILE}"
    echo "To run manually after building Multimedia API samples:" >> "${FILE}"
    echo "  cd /usr/src/jetson_multimedia_api/argus/samples/nvraw" >> "${FILE}"
    echo "  make && sudo ./nvargus_nvraw --sensorinfo" >> "${FILE}"
fi

write_section "${FILE}" "nvargus-daemon status"
if command -v systemctl > /dev/null 2>&1; then
    systemctl status nvargus-daemon --no-pager >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] systemctl not found" >> "${FILE}"
fi

write_section "${FILE}" "dmesg -- nvargus / nvraw messages"
dmesg 2>/dev/null | grep -i "nvargus\|nvraw" >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 11 -- ISP Tuning Files
# ------------------------------------------------------------------------------
print_header "Collecting 11 -- ISP Tuning Files"
FILE="${OUTPUT_DIR}/11_isp_tuning.txt"
write_header "${FILE}" "11 -- ISP Tuning Files"

# Known tuning file locations on L4T / JetPack
ISP_DIRS=(
    "/var/nvidia/nvcam/settings"
    "/opt/nvidia/nvcam/settings"
    "/etc/camera"
    "/etc/nvcam"
    "/usr/share/nvcam"
    "/usr/share/nvidia/nvcam"
)

write_section "${FILE}" "ISP tuning files in known directories"
for dir in "${ISP_DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
        echo "=== ${dir} ===" >> "${FILE}"
        find "${dir}" -type f \( \
            -name "*.isp" -o -name "*.nvtunefile" -o -name "*.xml" \
            -o -name "camera_overrides*" -o -name "*.cfg" \) 2>/dev/null \
            | while read -r tf; do
                echo "" >> "${FILE}"
                echo "--- ${tf} ---" >> "${FILE}"
                ls -la "${tf}" >> "${FILE}" 2>&1 || true
                cat "${tf}" >> "${FILE}" 2>&1 || true
            done
        echo "" >> "${FILE}"
    fi
done

write_section "${FILE}" "ISP tuning files in /var/nvidia/nvcam/settings"
if [[ -d /var/nvidia/nvcam/settings ]]; then
    find /var/nvidia/nvcam/settings -type f \( \
        -name "*.isp" -o -name "*.nvtunefile" -o -name "camera_overrides*" \) \
        2>/dev/null | while read -r tf; do
            echo "${tf}" >> "${FILE}"
            ls -lh "${tf}" >> "${FILE}" 2>&1 || true
        done
else
    echo "[INFO] /var/nvidia/nvcam/settings not found" >> "${FILE}"
fi

write_section "${FILE}" "Active ISP tuning file detection"
# Argus reads ARGUS_CAMERA_SRC and tuning paths from env / daemon config
echo "Environment variables (current shell):" >> "${FILE}"
env 2>/dev/null | grep -i "argus\|nvcam\|isp\|tuning\|nvraw" >> "${FILE}" 2>&1 || true

echo "" >> "${FILE}"
echo "nvargus-daemon environment (from /proc):" >> "${FILE}"
ARGUS_PID=$(pgrep -x nvargus-daemon 2>/dev/null || true)
if [[ -n "${ARGUS_PID}" ]]; then
    cat "/proc/${ARGUS_PID}/environ" 2>/dev/null | tr '\0' '\n' \
        | grep -i "argus\|nvcam\|isp\|tuning\|nvraw" >> "${FILE}" 2>&1 || true
    echo "" >> "${FILE}"
    echo "nvargus-daemon open files (lsof):" >> "${FILE}"
    if command -v lsof > /dev/null 2>&1; then
        lsof -p "${ARGUS_PID}" 2>/dev/null \
            | grep -i "\.isp\|\.nvtunefile\|\.xml\|nvcam\|tuning" >> "${FILE}" 2>&1 || true
    fi
else
    echo "[INFO] nvargus-daemon not running; cannot inspect open files" >> "${FILE}"
fi

write_section "${FILE}" "camera_overrides.isp usage indicator (sysfs / proc)"
# On Jetson, camera_overrides.isp in /var/nvidia/nvcam/settings/ activates tuning overrides
OVERRIDE_FILE="/var/nvidia/nvcam/settings/camera_overrides.isp"
if [[ -f "${OVERRIDE_FILE}" ]]; then
    echo "[ACTIVE] ${OVERRIDE_FILE} exists -- overrides ARE in use" >> "${FILE}"
    echo "" >> "${FILE}"
    cat "${OVERRIDE_FILE}" >> "${FILE}" 2>&1 || true
else
    echo "[INFO] ${OVERRIDE_FILE} not found -- no ISP overrides active at default path" >> "${FILE}"
fi

write_section "${FILE}" "nvcam / argus tuning packages"
dpkg -l 2>/dev/null | grep -i "nvcam\|argus\|isp\|tuning\|libcamera" >> "${FILE}" 2>&1 || true

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# 12 -- JetPack 6 Camera Listing (workaround for incorrect enumeration)
# ------------------------------------------------------------------------------
print_header "Collecting 12 -- JetPack 6 Camera Listing"
FILE="${OUTPUT_DIR}/12_jetpack6_camera_listing.txt"
write_header "${FILE}" "12 -- JetPack 6 Camera Listing"

# Determine L4T / JetPack major version
L4T_MAJOR=0
if [[ -f /etc/nv_tegra_release ]]; then
    L4T_MAJOR=$(grep -oP 'R\K[0-9]+' /etc/nv_tegra_release | head -1 || echo "0")
fi

write_section "${FILE}" "Detected L4T major version"
echo "L4T_MAJOR=${L4T_MAJOR}" >> "${FILE}"
cat /etc/nv_tegra_release >> "${FILE}" 2>&1 || true

if [[ "${L4T_MAJOR}" -ge 36 ]]; then
    echo "" >> "${FILE}"
    echo "[INFO] JetPack 6 detected (L4T R${L4T_MAJOR}.x)." >> "${FILE}"
    echo "       v4l2-ctl --list-devices may report incorrect device nodes." >> "${FILE}"
    echo "       Using sysfs-based enumeration below as workaround." >> "${FILE}"
fi

write_section "${FILE}" "v4l2-ctl --list-devices (standard, may be incorrect on JP6)"
if command -v v4l2-ctl > /dev/null 2>&1; then
    v4l2-ctl --list-devices >> "${FILE}" 2>&1 || true
else
    echo "[SKIP] v4l2-ctl not found" >> "${FILE}"
fi

write_section "${FILE}" "Sysfs-based camera enumeration (/sys/class/video4linux)"
# On JP6, this is the reliable way to identify actual capture devices
if [[ -d /sys/class/video4linux ]]; then
    echo "  Device            | Name                           | Capabilities" >> "${FILE}"
    echo "  ------------------+--------------------------------+----------------------------------" >> "${FILE}"
    for vdev in /sys/class/video4linux/video*/; do
        devname=$(basename "${vdev}")
        devnode="/dev/${devname}"
        vname=""
        [[ -f "${vdev}name" ]] && vname=$(cat "${vdev}name" 2>/dev/null || true)
        # Query capabilities via v4l2-ctl --info (more reliable than --list-devices on JP6)
        caps=""
        if command -v v4l2-ctl > /dev/null 2>&1 && [[ -c "${devnode}" ]]; then
            caps=$(v4l2-ctl -d "${devnode}" --info 2>/dev/null \
                | grep -i "device cap\|capabilities" | head -2 | tr '\n' ' ' || true)
        fi
        printf "  %-18s| %-30s | %s\n" "${devnode}" "${vname}" "${caps}" >> "${FILE}"
    done
else
    echo "[INFO] /sys/class/video4linux not found" >> "${FILE}"
fi

write_section "${FILE}" "Capture-capable devices only (VIDEO_CAPTURE flag in sysfs)"
# Filter only actual capture nodes (not metadata, output, m2m etc.)
if [[ -d /sys/class/video4linux ]] && command -v v4l2-ctl > /dev/null 2>&1; then
    echo "  Devices with VIDEO_CAPTURE capability:" >> "${FILE}"
    for vdev in /sys/class/video4linux/video*/; do
        devnode="/dev/$(basename "${vdev}")"
        if [[ -c "${devnode}" ]]; then
            if v4l2-ctl -d "${devnode}" --info 2>/dev/null \
                | grep -qi "video capture"; then
                vname=$(cat "${vdev}name" 2>/dev/null || true)
                echo "  ${devnode}  (${vname})" >> "${FILE}"
            fi
        fi
    done
else
    echo "[SKIP] v4l2-ctl or /sys/class/video4linux not available" >> "${FILE}"
fi

write_section "${FILE}" "Per-device --info output (JP6-safe enumeration)"
if command -v v4l2-ctl > /dev/null 2>&1; then
    for vdev in /sys/class/video4linux/video*/; do
        devnode="/dev/$(basename "${vdev}")"
        if [[ -c "${devnode}" ]]; then
            echo "=== ${devnode} ===" >> "${FILE}"
            v4l2-ctl -d "${devnode}" --info >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done
fi

write_section "${FILE}" "nvarguscamerasrc camera discovery (GStreamer)"
# nvarguscamerasrc num-cameras property shows what Argus sees -- more reliable on JP6
if command -v gst-launch-1.0 > /dev/null 2>&1; then
    echo "  Probing nvarguscamerasrc..." >> "${FILE}"
    # Quick probe: list cameras via nvarguscamerasrc
    timeout 5 gst-launch-1.0 nvarguscamerasrc num-buffers=0 ! fakesink 2>&1 \
        | grep -i "camera\|sensor\|found\|num-cameras\|error" \
        >> "${FILE}" 2>&1 || true
    echo "" >> "${FILE}"
    # Check num-cameras property
    if gst-inspect-1.0 nvarguscamerasrc > /dev/null 2>&1; then
        echo "nvarguscamerasrc properties:" >> "${FILE}"
        gst-inspect-1.0 nvarguscamerasrc 2>/dev/null \
            | grep -A2 "num-cameras\|sensor-id\|camera-id" \
            >> "${FILE}" 2>&1 || true
    fi
else
    echo "[SKIP] gst-launch-1.0 not found" >> "${FILE}"
fi

write_section "${FILE}" "media-ctl topology (JP6: camera nodes visible here)"
if command -v media-ctl > /dev/null 2>&1; then
    for mdev in /dev/media*; do
        if [[ -c "${mdev}" ]]; then
            echo "=== ${mdev} ===" >> "${FILE}"
            media-ctl -d "${mdev}" --print-topology >> "${FILE}" 2>&1 || true
            echo "" >> "${FILE}"
        fi
    done
else
    echo "[SKIP] media-ctl not found (install v4l-utils)" >> "${FILE}"
fi

write_section "${FILE}" "JP6 libcamera (if present)"
if command -v cam > /dev/null 2>&1; then
    timeout 5 cam --list >> "${FILE}" 2>&1 || true
else
    echo "[INFO] cam (libcamera) not found" >> "${FILE}"
fi

echo "  Done: ${FILE}"

# ------------------------------------------------------------------------------
# Create archive
# ------------------------------------------------------------------------------
print_header "Creating Archive"

echo "  Compressing ${OUTPUT_DIR} -> ${ARCHIVE_PATH}"
tar -czf "${ARCHIVE_PATH}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")" || {
    echo "  ERROR: Failed to create archive at ${ARCHIVE_PATH}"
    exit 1
}

# Transfer ownership back to the user who invoked sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${OUTPUT_DIR}" "${ARCHIVE_PATH}"
fi

ARCHIVE_SIZE=$(du -sh "${ARCHIVE_PATH}" 2>/dev/null | cut -f1 || echo "unknown")

echo ""
echo "======================================================================"
echo "  Support info collection complete!"
echo ""
echo "  Archive : ${ARCHIVE_PATH}"
echo "  Size    : ${ARCHIVE_SIZE}"
echo ""
echo "  Please send this archive to VC MIPI support:"
echo "    support@vision-components.com"
echo "======================================================================"
echo ""
