#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT_DIR"

# Git 2.35+ rejects the extracted tree because the Actions workspace is a
# bind mount owned by the host runner while the Ubuntu 20.04 container is root.
git config --global --add safe.directory '*'

mkdir -p build
cat > build/configuration.sh <<'EOF'
export VC_MIPI_SOM=NanoSD
export VC_MIPI_BOARD=NV_DevKit_Nano_A02
export VC_MIPI_BSP=32.7.5
EOF

cd bin
# Download/extract and patch the exact NVIDIA R32.7.5 kernel source.
./setup.sh --kernel
set +u
. config/configure.sh ""

mkdir -p "$TOOLCHAIN_DIR" "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"
download_and_check_file GCC
if [[ ! -x "$GCC_DIR/bin/aarch64-linux-gnu-gcc" ]]; then
	tar xf "$GCC_FILE" -C "$TOOLCHAIN_DIR"
fi

# build.sh normally copies these, but CI deliberately builds no rootfs.
mkdir -p "$DRIVER_DST_DIR"
cp -a "$DRIVER_DIR"/* "$DRIVER_DST_DIR"/

cd "$KERNEL_SOURCE"
make -C "$KERNEL_DIR" O="$KERNEL_OUT" -j"$(nproc)" tegra_defconfig
"$KERNEL_DIR/scripts/config" --file "$KERNEL_OUT/.config" \
	--module VIDEO_IMX296_WAVESHARE
make -C "$KERNEL_DIR" O="$KERNEL_OUT" -j"$(nproc)" \
	olddefconfig
# Build only the requested sensor module.  This target also runs modpost and
# links the .ko without compiling the complete Jetson kernel module set.
make -C "$KERNEL_DIR" O="$KERNEL_OUT" -j"$(nproc)" \
	drivers/media/i2c/imx296_waveshare.ko

OUT="$ROOT_DIR/artifacts/imx296-waveshare-nano-a02-r32.7.5"
rm -rf "$OUT"
mkdir -p "$OUT"
MODULE=$(find "$KERNEL_OUT" -name imx296_waveshare.ko -print -quit)
test -n "$MODULE"
cp "$MODULE" "$OUT/"
cp "$ROOT_DIR/doc/IMX296_NANO_A02.md" "$OUT/INSTALL.md"
cp "$ROOT_DIR/target/install_imx296_nano_a02.sh" "$OUT/"
printf 'source=%s\ncommit=%s\nl4t=32.7.5\n' \
	"${GITHUB_REPOSITORY:-local}" "${GITHUB_SHA:-local}" > "$OUT/BUILD-INFO.txt"
(cd "$OUT" && sha256sum imx296_waveshare.ko > SHA256SUMS)
