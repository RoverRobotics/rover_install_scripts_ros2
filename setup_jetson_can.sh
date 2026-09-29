#!/bin/bash
#########################################################################
# Script Name  : Jetson USB-CAN Setup                                   #
# Description  : Builds gs_usb kernel module, installs udev rule for    #
#                stable naming (rovercan), writes /usr/sbin/enablecan   #
#                and /etc/systemd/system/can.service, enables the       #
#                service so rovercan comes up at every boot.            #
# Target       : Jetson L4T R36.x, kernel 5.15.x-tegra or 6.8.x-tegra   #
# Adapter      : gs_usb family (VID 1d50 / PID 606f), classic CAN only  #
#                (candleLight / CANable / InnoMaker USB2CAN V3.3 etc.)  #
# Usage        : ./setup_jetson_can.sh                                  #
#                (do NOT prefix with sudo; the script calls sudo as     #
#                 needed and will prompt for your password once)        #
#########################################################################

set -euo pipefail

#########################################################################
#                             CONFIG                                    #
#########################################################################

BUILD_DIR="$HOME/gs_usb_build"
BITRATE=500000
IFACE_NAME="rovercan"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDEV_RULE_DEST="/etc/udev/rules.d/99-can-usb.rules"

# Look for the repo-sourced udev rule in a few plausible locations.
# If none are found, the script falls back to writing the rule inline - so
# you can run this on a fresh Jetson with only the script itself present.
UDEV_RULE_SRC=""
for candidate in \
  "$SCRIPT_DIR/udev/99-can-usb.rules" \
  "$HOME/rover_install_scripts_ros2/udev/99-can-usb.rules" \
  "/home/rover/rover_install_scripts_ros2/udev/99-can-usb.rules"; do
  if [[ -f "$candidate" ]]; then
    UDEV_RULE_SRC="$candidate"
    break
  fi
done

#########################################################################
#                          HELPER FUNCTIONS                             #
#########################################################################

info()  { echo -e "\n\033[1;34m[*]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[warn]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

#########################################################################
#                         PREFLIGHT CHECKS                              #
#########################################################################

info "Preflight checks"

if [[ $EUID -eq 0 ]]; then
  fail "Do not run this script as root. Run as your normal user; sudo is used internally."
fi

need_cmd uname
need_cmd wget
need_cmd make
need_cmd gcc
need_cmd sudo
need_cmd ip
need_cmd systemctl
need_cmd udevadm

KERNEL_VERSION="$(uname -r)"
KERNEL_MAJOR_MINOR="$(echo "$KERNEL_VERSION" | cut -d. -f1-2)"
ok "Kernel: $KERNEL_VERSION (major.minor = $KERNEL_MAJOR_MINOR)"

# Choose matching Linux source tag
case "$KERNEL_MAJOR_MINOR" in
  5.15) SRC_TAG="v5.15" ;;
  6.8)  SRC_TAG="v6.8"  ;;
  *)    fail "Unsupported kernel major.minor: $KERNEL_MAJOR_MINOR. Edit the script to add a source tag." ;;
esac
ok "Using Linux source tag: $SRC_TAG"

KHEADERS="/lib/modules/$KERNEL_VERSION/build"
if [[ ! -d "$KHEADERS" ]]; then
  fail "Kernel headers not found at $KHEADERS. Install with: sudo apt install nvidia-l4t-kernel-headers"
fi
ok "Kernel headers present"

# Check whether CAN_GS_USB is already compiled into the kernel. If so, skip build.
if zcat /proc/config.gz 2>/dev/null | grep -qE "^CONFIG_CAN_GS_USB=(y|m)"; then
  warn "CONFIG_CAN_GS_USB is already enabled in kernel config; skipping out-of-tree build."
  SKIP_BUILD=1
else
  SKIP_BUILD=0
fi

if [[ -n "$UDEV_RULE_SRC" ]]; then
  ok "udev rule source found at $UDEV_RULE_SRC"
else
  warn "No repo udev rule found; will write rule inline"
fi

# Ask for sudo once so the rest of the script doesn't interrupt
info "This script needs sudo for module install, udev rule install, and systemd setup."
sudo -v
( while true; do sudo -v; sleep 30; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

#########################################################################
#            STEP 1 - BUILD AND INSTALL gs_usb KERNEL MODULE            #
#########################################################################

if [[ $SKIP_BUILD -eq 0 ]]; then
  info "Step 1/5 - Build gs_usb.ko"

  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  SRC_URL="https://raw.githubusercontent.com/torvalds/linux/$SRC_TAG/drivers/net/can/usb/gs_usb.c"
  if [[ ! -f gs_usb.c ]]; then
    wget -q --show-progress "$SRC_URL" -O gs_usb.c || fail "Could not download $SRC_URL"
    ok "Downloaded gs_usb.c from $SRC_TAG"
  else
    ok "gs_usb.c already present; not re-downloading"
  fi

  # Write the Makefile (recipe lines must use tabs - printf preserves \t literals)
  cat > Makefile <<'EOF'
obj-m := gs_usb.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

  # Rebuild if no .ko, or if the .ko's vermagic doesn't match this kernel.
  NEED_BUILD=1
  if [[ -f gs_usb.ko ]]; then
    if modinfo gs_usb.ko 2>/dev/null | grep -q "vermagic:.*$KERNEL_VERSION"; then
      NEED_BUILD=0
      ok "Existing gs_usb.ko vermagic matches $KERNEL_VERSION; skipping rebuild"
    fi
  fi

  if [[ $NEED_BUILD -eq 1 ]]; then
    make clean >/dev/null 2>&1 || true
    make || fail "Build failed. Check that source tag $SRC_TAG matches your kernel."
    ok "Built gs_usb.ko"
  fi

  info "Installing gs_usb.ko to /lib/modules/$KERNEL_VERSION/updates/"
  sudo mkdir -p "/lib/modules/$KERNEL_VERSION/updates"
  sudo cp gs_usb.ko "/lib/modules/$KERNEL_VERSION/updates/"
  sudo depmod -a
  ok "Module installed"
else
  info "Step 1/5 - skipping build (driver in-tree)"
fi

info "Loading gs_usb module"
if lsmod | grep -q '^gs_usb'; then
  ok "gs_usb already loaded"
else
  sudo modprobe gs_usb || fail "Failed to modprobe gs_usb"
  ok "gs_usb loaded (the 'tainting kernel: signature missing' warning is expected)"
fi

#########################################################################
#                    STEP 2 - INSTALL udev RULE                         #
#########################################################################

info "Step 2/5 - Install udev rule for stable name $IFACE_NAME"

if [[ -n "$UDEV_RULE_SRC" ]]; then
  sudo cp "$UDEV_RULE_SRC" "$UDEV_RULE_DEST"
else
  sudo tee "$UDEV_RULE_DEST" > /dev/null <<'EOF'
# Renames the gs_usb CAN adapter (VID 1d50 / PID 606f - candleLight family) to
# stable name rovercan so enablecan does not depend on canX probe order.
# NAME= does not work for socketcan (net_setup_link ignores it); RUN+= with
# `ip link set` is used instead. Filename 99-* runs after 80-net-setup-link.rules.
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="606f", NAME="rovercan"
EOF
fi
sudo chmod 644 "$UDEV_RULE_DEST"
sudo udevadm control --reload-rules
ok "Rule installed at $UDEV_RULE_DEST"

# Apply the rename to whatever gs_usb interface is currently present (if any).
# On a fresh plug-in after reboot, udev handles this automatically; here we
# just cover the case where the adapter is already plugged in.
CURRENT_GS_USB_IFACE=""
for i in 0 1 2 3 4 5 6 7; do
  if [[ -L "/sys/class/net/can$i/device/driver" ]]; then
    drv="$(basename "$(readlink "/sys/class/net/can$i/device/driver")")"
    if [[ "$drv" == "gs_usb" ]]; then
      CURRENT_GS_USB_IFACE="can$i"
      break
    fi
  fi
done

if [[ -n "$CURRENT_GS_USB_IFACE" ]]; then
  info "Found live gs_usb interface at $CURRENT_GS_USB_IFACE; renaming to $IFACE_NAME"
  sudo ip link set "$CURRENT_GS_USB_IFACE" down 2>/dev/null || true
  sudo ip link set "$CURRENT_GS_USB_IFACE" name "$IFACE_NAME" \
    || warn "Could not rename live interface (will take effect on next plug-in / reboot)"
elif ip link show "$IFACE_NAME" &>/dev/null; then
  ok "$IFACE_NAME already present"
else
  warn "No gs_usb adapter currently plugged in. Rule is installed; plug in the adapter (or reboot) to trigger the rename."
fi

#########################################################################
#               STEP 3 - INSTALL /usr/sbin/enablecan                    #
#########################################################################

info "Step 3/5 - Install /usr/sbin/enablecan"

sudo tee /usr/sbin/enablecan > /dev/null <<EOF
#!/bin/bash
set -e
IFACE=$IFACE_NAME
for i in {1..30}; do
  ip link show "\$IFACE" &>/dev/null && break
  sleep 0.5
done
if ! ip link show "\$IFACE" &>/dev/null; then
  echo "enablecan: \$IFACE not found after 15s" >&2
  exit 1
fi
ip link set "\$IFACE" down 2>/dev/null || true
ip link set "\$IFACE" type can bitrate $BITRATE
ip link set "\$IFACE" up
EOF
sudo chmod +x /usr/sbin/enablecan
ok "enablecan installed (bitrate=$BITRATE, iface=$IFACE_NAME)"

#########################################################################
#          STEP 4 - INSTALL /etc/systemd/system/can.service             #
#########################################################################

info "Step 4/5 - Install can.service unit"

sudo tee /etc/systemd/system/can.service > /dev/null <<'EOF'
[Unit]
Description=Bring up CAN interface
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/enablecan
RemainAfterExit=true
TimeoutStartSec=45
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
ok "can.service installed"

#########################################################################
#                STEP 5 - RELOAD, ENABLE, AND START                     #
#########################################################################

info "Step 5/5 - Enable and start can.service"

sudo systemctl daemon-reload
sudo systemctl enable can.service
sudo systemctl restart can.service || warn "can.service did not start cleanly - check 'journalctl -u can.service'"

sleep 1
if systemctl is-active --quiet can.service; then
  ok "can.service is active"
else
  warn "can.service is not active; see 'systemctl status can.service'"
fi

#########################################################################
#                          FINAL SUMMARY                                #
#########################################################################

info "Summary"

echo
echo "  Interface state:"
ip -br link show "$IFACE_NAME" 2>/dev/null | sed 's/^/    /' \
  || echo "    $IFACE_NAME not present yet (plug in adapter or reboot)"

echo
echo "  Files installed:"
echo "    $UDEV_RULE_DEST"
echo "    /usr/sbin/enablecan"
echo "    /etc/systemd/system/can.service"
echo "    /lib/modules/$KERNEL_VERSION/updates/gs_usb.ko"

echo
echo "  Next steps:"
echo "    - If the adapter is plugged in and you see 'UP,LOWER_UP', you're done."
echo "    - If you see 'DOWN' or the interface is missing, unplug/replug the adapter"
echo "      and run: sudo systemctl restart can.service"
echo "    - Reboot to verify the setup survives a full boot cycle."
echo "    - Update your ROS config's device_port to: $IFACE_NAME"
echo

ok "Setup complete."
