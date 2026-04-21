# Jetson CAN Setup — Quickstart

Setup for USB-CAN (gs_usb) → VESC on a Jetson. Target: L4T R36.x, kernel `5.15.x-tegra`,
candleLight-family adapter (USB ID `1d50:606f`), VESC on classic CAN at 500 kbps.

## 1. Verify system

```bash
uname -r                                   # 5.15.x-tegra
zcat /proc/config.gz | grep CAN_GS_USB     # "not set" → build needed
ls /lib/modules/$(uname -r)/build          # headers must exist; else apt install nvidia-l4t-kernel-headers
```

## 2. Build gs_usb.ko out-of-tree

Source tag must match `uname -r` major.minor (`v5.15` for 5.15.x, `v6.8` for 6.8.x, …).

```bash
mkdir -p ~/gs_usb_build && cd ~/gs_usb_build
wget https://raw.githubusercontent.com/torvalds/linux/v5.15/drivers/net/can/usb/gs_usb.c
printf 'obj-m := gs_usb.o\nKDIR := /lib/modules/$(shell uname -r)/build\nPWD := $(shell pwd)\n\nall:\n\t$(MAKE) -C $(KDIR) M=$(PWD) modules\n\nclean:\n\t$(MAKE) -C $(KDIR) M=$(PWD) clean\n' > Makefile
make
```

"Compiler differs from the one used to build the kernel" is a harmless warning.

## 3. Install and load

```bash
sudo mkdir -p /lib/modules/$(uname -r)/updates
sudo cp gs_usb.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a
sudo modprobe gs_usb
lsmod | grep gs_usb
```

The `tainting kernel: signature missing` warning is expected for OOT modules.

## 4. udev rule for stable name

Source file already in the repo at `udev/99-can-usb.rules`:

```
SUBSYSTEM=="net", KERNEL=="can*", ACTION=="add", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="606f", RUN+="/bin/ip link set %k name can_usb"
```

Install and reload:

```bash
sudo cp ~/rover_install_scripts_ros2/udev/99-can-usb.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Unplug/replug the adapter to trigger the rename. Verify with `ip -br link show type can`
— expect `can_usb DOWN`.

**Non-obvious bits** (don't "fix" these without reading):
- Filename is `99-*`, not `80-*`. Must run after `/usr/lib/udev/rules.d/80-net-setup-link.rules`.
- `RUN+="/bin/ip link set …"`, not `NAME="can_usb"`. `net_setup_link` ignores `NAME=`
  for socketcan devices, so `NAME=` silently does nothing.
- Matching uses `ATTRS{}` (sysfs walk), not `ENV{}`. `ENV{ID_NET_DRIVER}` isn't
  populated until `80-net-setup-link.rules` runs.

## 5. Fixed enablecan

Replace `/usr/sbin/enablecan`:

```bash
#!/bin/bash
set -e
IFACE=can_usb
for i in {1..30}; do
  ip link show "$IFACE" &>/dev/null && break
  sleep 0.5
done
if ! ip link show "$IFACE" &>/dev/null; then
  echo "enablecan: $IFACE not found after 15s" >&2
  exit 1
fi
ip link set "$IFACE" down 2>/dev/null || true
ip link set "$IFACE" type can bitrate 500000
ip link set "$IFACE" up
```

`sudo chmod +x /usr/sbin/enablecan` after writing.

Watch out for:
- **Don't** leave `sudo` inside the script. Systemd runs it as root already.
- **Don't** skip the `ip link set down` before `type can bitrate …` or you get
  `RTNETLINK: Device or resource busy` on re-runs.
- **Don't** use `fd on`/`dbitrate` — the candleLight adapter (VID 1d50/PID 606f) is
  classic-CAN only. Verify with `ip -details link show can_usb`: no `dtseg*` ranges
  means no FD.
- The wait loop is needed because udev-driven rename can race with service start.

## 6. Enable service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now can.service
systemctl status can.service --no-pager
ip -br link show can_usb    # expect UP,LOWER_UP,ECHO
```

Stock `can.service` unit from L4T is fine as-is (`Type=oneshot`, `After=network.target`).

## 7. ROS config

`device_port: "can_usb"` in the active robot config under
`~/rover_workspace/src/roverrobotics_ros2/roverrobotics_driver/config/<model>_config.yaml`.
Rebuild: `colcon build --symlink-install`.

## 8. Reboot test

```bash
sudo reboot
# after login:
ip -br link show can_usb    # UP,LOWER_UP expected
candump can_usb             # VESC telemetry streaming
```

---

## Gotchas worth remembering

- **Kernel upgrade breaks the module.** `apt upgrade` of `nvidia-l4t-kernel` changes
  `uname -r`; your `.ko` no longer matches. Rebuild + reinstall as in steps 2–3.
  Prevent with `sudo apt-mark hold nvidia-l4t-kernel nvidia-l4t-kernel-headers`.
- **No LOWER_UP** = driver's up but nothing on the bus is ACKing. Check VESC power,
  wiring polarity, 120Ω termination, and that the VESC is configured for 500k classic
  CAN (not FD).
- **Swapping adapters**: any `1d50:606f` device matches the rule — plug-and-play
  interchangeable. Different VID/PID? Edit the rule or add a second line.
- **Different bitrate**: change `500000` in `/usr/sbin/enablecan`.
- **Rule debug**: `udevadm test /sys/class/net/canN` shows what rules fire and what
  env vars are set. Look for a line naming your rule file — its absence means no
  match. `systemd v249` (shipped on this L4T) does **not** have `udevadm verify`;
  don't bother looking for it.
- **can0 on this machine is on-chip MTTCAN**, not the USB adapter. MTTCAN is
  currently unwired; don't confuse its bus-off errors for USB-CAN problems.
