# Waveshare IMX296 on Jetson Nano A02

This target is for JetPack 4.6.5 / L4T R32.7.5 only. Connect the Waveshare
IMX296 Global Camera (A) to the A02 CAM0 connector with power removed. On the
Jetson connector the cable contacts face toward the module/heatsink.

## Install

The Workflow artifact is module-only. It includes an installer that validates
the Jetson architecture, L4T release and module vermagic, creates a one-time
module backup, loads the driver immediately and enables it at boot:

```bash
chmod +x install_imx296_nano_a02.sh
sudo ./install_imx296_nano_a02.sh install --reboot
```

The camera will probe only when the A02 IMX296 device-tree node is already
installed and enabled. The module-only installer deliberately does not replace
the board DTB. For a manual module installation, use the following commands.

```bash
L4T=$(head -n1 /etc/nv_tegra_release)
echo "$L4T"                         # must report R32 revision 7.5
uname -r                           # expected 4.9.337-tegra
sudo install -m 0644 imx296_waveshare.ko \
  /lib/modules/$(uname -r)/kernel/drivers/media/i2c/
echo imx296_waveshare | sudo tee /etc/modules-load.d/imx296-waveshare.conf
sudo depmod -a
sudo modprobe imx296_waveshare
```

The repository also contains the A02 device-tree source and patches, but the
module-only Workflow does not compile or deploy them. If the IMX296 node has
not previously been installed, deploy a matching A02 DTB separately before
expecting `/dev/video*` to appear.

## Verify

```bash
dmesg | grep -i -E 'imx296|nvcsi|tegra-capture-vi'
media-ctl -p
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=1456,height=1088,pixelformat=RG10 \
  --stream-mmap --stream-count=1000 --stream-to=imx296.raw
```

Exposure, analogue gain and frame rate are exposed as standard tegracam V4L2
controls. Use `v4l2-ctl -d /dev/video0 --list-ctrls` to inspect their ranges.

## Remove the module

```bash
sudo ./install_imx296_nano_a02.sh uninstall --reboot
```

The equivalent manual procedure is:

```bash
sudo modprobe -r imx296_waveshare
sudo rm -f /etc/modules-load.d/imx296-waveshare.conf
sudo rm -f /lib/modules/$(uname -r)/kernel/drivers/media/i2c/imx296_waveshare.ko
sudo depmod -a
```
