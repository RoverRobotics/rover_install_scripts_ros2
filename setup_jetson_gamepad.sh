#!/bin/bash
#########################################################################
# Script Name  : Jetson Gamepad Driver Setup                            #
# Description  : Builds the PlayStation pad HID driver as an out-of-tree #
#                kernel module and installs it into                     #
#                /lib/modules/<kernel>/updates. No kernel rebuild and   #
#                no reflash. Picks the right driver for the running     #
#                kernel and forces the force-feedback build flags on.   #
# Target       : Jetson L4T R36.x (JetPack 6, 5.15.x-tegra, Ubuntu      #
#                22.04) and R39.x (JetPack 7, 6.8.x-tegra, 24.04)       #
# Why          : the stock L4T kernels ship no PlayStation pad driver,  #
#                so a DualShock 4 falls back to hid-generic, which      #
#                decodes only its simple report mode and goes silent    #
#                when the pad switches to extended mode.                #
# Usage        : ./setup_jetson_gamepad.sh              (build only)    #
#                ./setup_jetson_gamepad.sh --install    (+ updates/,    #
#                                            udev rules, plugdev)       #
#                ./setup_jetson_gamepad.sh --load       (+ modprobe)    #
#                ./setup_jetson_gamepad.sh --uninstall                  #
#                (do NOT prefix with sudo; sudo is called internally)   #
#########################################################################

set -euo pipefail

#########################################################################
#                             CONFIG                                    #
#########################################################################

BUILD_DIR="$HOME/gamepad_build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDEV_RULE_NAME="70-rover-gamepad.rules"
UDEV_RULE_DEST="/etc/udev/rules.d/$UDEV_RULE_NAME"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
UPDATES_DIR="/lib/modules/$KVER/updates"
SRC_BASE="https://raw.githubusercontent.com/torvalds/linux"

DO_INSTALL=0
DO_LOAD=0
DO_UNINSTALL=0
KEEP_BUILD=0
TAG_OVERRIDE=""

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

# Reads the running kernel's config from whichever source this build exposes.
kconfig() {
  if [[ -f /proc/config.gz ]]; then
    zcat /proc/config.gz
  elif [[ -f "/boot/config-$KVER" ]]; then
    cat "/boot/config-$KVER"
  elif [[ -f "$KDIR/.config" ]]; then
    cat "$KDIR/.config"
  fi
}

# y, m, or unset for one CONFIG symbol.
config_state() {
  local sym="$1" line
  line="$(kconfig | grep -E "^CONFIG_${sym}=|^# CONFIG_${sym} is not set" | head -1 || true)"
  case "$line" in
    "CONFIG_${sym}=y") echo y ;;
    "CONFIG_${sym}=m") echo m ;;
    *)                 echo unset ;;
  esac
}

#########################################################################
#                       ARGUMENT PARSING                                #
#########################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   DO_INSTALL=1; shift ;;
    --load)      DO_INSTALL=1; DO_LOAD=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --keep)      KEEP_BUILD=1; shift ;;
    --tag)       TAG_OVERRIDE="${2:?--tag needs a value, e.g. v6.8}"; shift 2 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *)           fail "Unknown option: $1 (try --help)" ;;
  esac
done

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
need_cmd modinfo
need_cmd depmod

ok "Kernel: $KVER"

KMM="$(echo "$KVER" | cut -d. -f1-2)"

# Driver choice is NOT cosmetic. On 5.15 hid-sony owns the DualShock 4 and
# hid-playstation is DualSense-only; on 6.8 that ownership moves to
# hid-playstation and hid-sony handles PS3 pads only.
case "$KMM" in
  5.15)
    SRC_TAG="v5.15"
    PAD_MOD="hid-sony"
    PAD_CONFIG="HID_SONY"
    FF_DEFINES="-DCONFIG_SONY_FF"
    JETPACK="6 (Ubuntu 22.04)"
    ;;
  6.8)
    SRC_TAG="v6.8"
    PAD_MOD="hid-playstation"
    PAD_CONFIG="HID_PLAYSTATION"
    FF_DEFINES="-DCONFIG_PLAYSTATION_FF"
    JETPACK="7 (Ubuntu 24.04)"
    ;;
  *)
    fail "Unsupported kernel $KVER. This script knows 5.15.x-tegra (JetPack 6) and 6.8.x-tegra (JetPack 7)."
    ;;
esac

[[ -n "$TAG_OVERRIDE" ]] && SRC_TAG="$TAG_OVERRIDE"

ok "JetPack $JETPACK -> driver $PAD_MOD, source tag $SRC_TAG"

#########################################################################
#                            UNINSTALL                                  #
#########################################################################

if [[ $DO_UNINSTALL -eq 1 ]]; then
  info "Uninstalling $PAD_MOD"
  mod_underscore="${PAD_MOD//-/_}"
  if lsmod | grep -q "^${mod_underscore} "; then
    sudo modprobe -r "$PAD_MOD" 2>/dev/null \
      && ok "Unloaded $PAD_MOD" \
      || warn "Could not unload $PAD_MOD (a pad may be in use); it will be gone after a reboot"
  fi
  removed=0
  for f in "$UPDATES_DIR/$PAD_MOD.ko" "$UPDATES_DIR/led-class-multicolor.ko"; do
    if [[ -f "$f" ]]; then
      sudo rm -f "$f" && ok "Removed $f" && removed=1
    fi
  done
  [[ $removed -eq 0 ]] && warn "Nothing of ours was installed in $UPDATES_DIR"
  if [[ -f "$UDEV_RULE_DEST" ]]; then
    sudo rm -f "$UDEV_RULE_DEST" && ok "Removed $UDEV_RULE_DEST"
    sudo udevadm control --reload-rules
  fi
  sudo rm -f "/etc/modules-load.d/$PAD_MOD.conf"
  sudo depmod -a
  ok "depmod refreshed. The stock kernel behaviour is restored."
  exit 0
fi

#########################################################################
#                  ALREADY PRESENT? THEN DO NOTHING                     #
#########################################################################

info "Checking whether this kernel already has $PAD_MOD"

PAD_STATE="$(config_state "$PAD_CONFIG")"
PAD_ON_DISK="$(find "/lib/modules/$KVER" -name "$PAD_MOD.ko*" 2>/dev/null | head -1 || true)"

if [[ "$PAD_STATE" != "unset" || -n "$PAD_ON_DISK" ]]; then
  ok "CONFIG_$PAD_CONFIG=$PAD_STATE; module on disk: ${PAD_ON_DISK:-none}"
  warn "This kernel already provides $PAD_MOD. Nothing to build."
  warn "If the pad still misbehaves the problem is the button map or udev, not the driver."
  exit 0
fi

ok "CONFIG_$PAD_CONFIG is not set and no $PAD_MOD.ko is on disk - build needed"

#########################################################################
#                      KERNEL BUILD TREE CHECK                          #
#########################################################################

info "Checking the kernel build tree"

# A custom-flashed kernel leaves this symlink pointing at the build host's
# source tree, so test that it RESOLVES. `ls` happily lists a dangling link.
if [[ ! -d "$KDIR" ]]; then
  echo "  $KDIR -> $(readlink "$KDIR" 2>/dev/null || echo '(missing)')"
  warn "The kernel build symlink does not resolve."
  # A custom-flashed kernel leaves this pointing at the source tree on the
  # machine that built it. The headers package is usually still installed, so
  # look for a real KBUILD root before giving up.
  FOUND_KBUILD=""
  while IFS= read -r cand; do
    [[ -f "$cand/Makefile" && -f "$cand/Module.symvers" ]] && { FOUND_KBUILD="$cand"; break; }
  done < <(find /usr/src -maxdepth 5 -type d -name 'linux-*' 2>/dev/null | grep -F "$KVER" | sort)

  if [[ -n "$FOUND_KBUILD" ]]; then
    fail "Installed headers for this kernel were found, but $KDIR does not point at them.
  Repoint it and run this script again:

    sudo ln -sfn $FOUND_KBUILD \\
                 $KDIR"
  fi
  fail "No usable kernel build tree, and no installed headers found for $KVER.
  Install them with:  sudo apt install nvidia-l4t-kernel-headers
  If this kernel was custom-built, copy the build tree from the machine that
  built it, or rebuild from public_sources on this device."
fi

for f in Makefile Module.symvers scripts/Makefile.build; do
  [[ -e "$KDIR/$f" ]] || fail "Kernel build tree at $KDIR is incomplete (missing $f)."
done
ok "Build tree usable: $(readlink -f "$KDIR")"

KERNEL_GCC="$(sed -n 's/.*) (\(.*\), GNU ld.*/\1/p' /proc/version 2>/dev/null | head -1 || true)"
RUNNING_GCC="$(gcc --version | head -1)"
[[ -n "$KERNEL_GCC" ]] && echo "  kernel built with: $KERNEL_GCC"
echo "  building with:     $RUNNING_GCC"
warn "A 'compiler differs' notice from kbuild is expected and harmless when only the patch level differs."

#########################################################################
#                    DEPENDENCY: LED MULTICOLOR CLASS                   #
#########################################################################

# hid-playstation calls led_classdev_multicolor_register_ext, so without this
# class the module builds fine and then fails to load on an unknown symbol.
BUILD_LEDMC=0
if [[ "$PAD_MOD" == "hid-playstation" ]]; then
  info "Checking hid-playstation's LED dependency"
  LEDMC_STATE="$(config_state LEDS_CLASS_MULTICOLOR)"
  LEDMC_ON_DISK="$(find "/lib/modules/$KVER" -name 'led-class-multicolor.ko*' 2>/dev/null | head -1 || true)"
  if [[ "$LEDMC_STATE" != "unset" || -n "$LEDMC_ON_DISK" ]]; then
    ok "LEDS_CLASS_MULTICOLOR=$LEDMC_STATE; module: ${LEDMC_ON_DISK:-none} - dependency satisfied"
  else
    warn "LEDS_CLASS_MULTICOLOR is not set and no led-class-multicolor.ko exists; building it too"
    BUILD_LEDMC=1
  fi
fi

#########################################################################
#                        FETCH DRIVER SOURCES                           #
#########################################################################

info "Fetching sources at $SRC_TAG"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

fetch() {
  local path="$1" dest
  dest="$(basename "$path")"
  if [[ -f "$dest" ]]; then
    ok "$dest already present (delete it to re-fetch)"
  else
    wget -q "$SRC_BASE/$SRC_TAG/$path" -O "$dest" \
      || { rm -f "$dest"; fail "Could not download $path at $SRC_TAG"; }
    ok "$dest ($(wc -l < "$dest") lines)"
  fi
}

# The L4T build tree carries no driver sources, so hid-ids.h comes with it.
fetch "drivers/hid/$PAD_MOD.c"
fetch "drivers/hid/hid-ids.h"
[[ $BUILD_LEDMC -eq 1 ]] && fetch "drivers/leds/led-class-multicolor.c"

#########################################################################
#                              BUILD                                    #
#########################################################################

info "Building $PAD_MOD with force feedback enabled"

# Out of tree the kernel's autoconf.h has these symbols unset, so the rumble
# code would be compiled out silently. The -D flags are what switch it on.
# Write -DCONFIG_X and never -DCONFIG_X=y. hid-playstation gates on
# IS_ENABLED(), which is true only when the symbol expands to exactly 1;
# bare -DCONFIG_X gives 1, while =y evaluates to 0 and kills rumble silently.
{
  echo "obj-m := $PAD_MOD.o"
  [[ $BUILD_LEDMC -eq 1 ]] && echo "obj-m += led-class-multicolor.o"
  echo "ccflags-y += $FF_DEFINES"
  echo "KDIR := $KDIR"
  echo "PWD := \$(shell pwd)"
  echo ""
  echo "all:"
  printf '\t$(MAKE) -C $(KDIR) M=$(PWD) modules\n'
  echo ""
  echo "clean:"
  printf '\t$(MAKE) -C $(KDIR) M=$(PWD) clean\n'
} > Makefile

make clean >/dev/null 2>&1 || true
make || fail "Build failed. If the errors are API mismatches, the source tag $SRC_TAG does not match this kernel; try --tag."

[[ -f "$PAD_MOD.ko" ]] || fail "Build reported success but $PAD_MOD.ko is missing."
ok "Built $PAD_MOD.ko ($(stat -c%s "$PAD_MOD.ko") bytes)"

#########################################################################
#                            VERIFY                                     #
#########################################################################

info "Verifying the built module"

BUILT_VERMAGIC="$(modinfo "$PAD_MOD.ko" 2>/dev/null | awk '/^vermagic/{$1="";print}' | xargs || true)"
echo "  vermagic: $BUILT_VERMAGIC"
case "$BUILT_VERMAGIC" in
  "$KVER"*) ok "vermagic matches the running kernel" ;;
  *)        fail "vermagic does not match $KVER. This module would be refused at load." ;;
esac

# The whole point of FF_DEFINES; without the symbol the pad has no rumble and
# nothing anywhere says so.
if nm "$PAD_MOD.ko" 2>/dev/null | grep -q 'input_ff_create_memless'; then
  ok "Force feedback is linked in (input_ff_create_memless present)"
else
  warn "Force feedback is NOT linked in. The pad will work but rumble will be silently dead."
  warn "Check that $FF_DEFINES matches the CONFIG symbol this kernel's driver uses."
fi

if [[ $DO_INSTALL -eq 0 ]]; then
  echo
  ok "Build only - nothing installed and nothing loaded."
  echo "  Module: $BUILD_DIR/$PAD_MOD.ko"
  echo "  Install it with: $0 --install     (then modprobe $PAD_MOD)"
  echo "  Install and load in one step:     $0 --load"
  exit 0
fi

#########################################################################
#                             INSTALL                                   #
#########################################################################

info "Installing into $UPDATES_DIR"

sudo mkdir -p "$UPDATES_DIR"
sudo cp "$PAD_MOD.ko" "$UPDATES_DIR/"
ok "Installed $UPDATES_DIR/$PAD_MOD.ko"

if [[ $BUILD_LEDMC -eq 1 && -f led-class-multicolor.ko ]]; then
  sudo cp led-class-multicolor.ko "$UPDATES_DIR/"
  ok "Installed $UPDATES_DIR/led-class-multicolor.ko"
fi

sudo depmod -a
ok "depmod refreshed (updates/ takes precedence over the stock tree)"

# modules-load.d makes it survive a reboot; without it the module is only
# pulled in when a matching device appears, which is usually enough but not
# guaranteed for a pad that is already attached at boot.
echo "$PAD_MOD" | sudo tee "/etc/modules-load.d/$PAD_MOD.conf" >/dev/null
ok "Wrote /etc/modules-load.d/$PAD_MOD.conf"

#########################################################################
#                      UDEV RULES AND GROUP                             #
#########################################################################

info "Installing udev rules for pad access and stable names"

# The driver alone is not enough: without these the event node stays
# root:input, so the rover user cannot open it and force feedback fails with
# "Couldn't open joystick force feedback: Bad file descriptor".
# 70, not 55: the match needs ID_INPUT_JOYSTICK, which udev only sets in
# 60-input-id.rules, so the same rule in a 55- file never fires.
UDEV_SRC=""
for candidate in \
  "$SCRIPT_DIR/udev/$UDEV_RULE_NAME" \
  "$HOME/rover_install_scripts_ros2/udev/$UDEV_RULE_NAME"; do
  [[ -f "$candidate" ]] && { UDEV_SRC="$candidate"; break; }
done

if [[ -n "$UDEV_SRC" ]]; then
  sudo cp "$UDEV_SRC" "$UDEV_RULE_DEST"
  ok "Installed $UDEV_RULE_DEST (from $UDEV_SRC)"
else
  sudo tee "$UDEV_RULE_DEST" >/dev/null <<'EOF_UDEV'
# Must sort AFTER 60-input-id.rules, which is where udev sets ID_INPUT_JOYSTICK.
# Rumble access for any gamepad the kernel calls a joystick.
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_JOYSTICK}=="1", GROUP="plugdev", MODE="0660"
# Stable names for a Sony pad (054c): PS5 DualSense and PS4 DualShock 4.
SUBSYSTEM=="input", KERNEL=="js[0-9]*",    ATTRS{id/vendor}=="054c", ENV{ID_INPUT_JOYSTICK}=="1", GROUP="plugdev", MODE="0660", SYMLINK+="rover-pad"
SUBSYSTEM=="input", KERNEL=="event[0-9]*", ATTRS{id/vendor}=="054c", ENV{ID_INPUT_JOYSTICK}=="1", GROUP="plugdev", MODE="0660", SYMLINK+="rover-pad-ff"
EOF_UDEV
  ok "Wrote $UDEV_RULE_DEST (inline copy)"
fi

# The rules grant to plugdev; without the membership they grant nothing.
if id -nG "$USER" | grep -qw plugdev; then
  ok "$USER is already in plugdev"
elif sudo usermod -aG plugdev "$USER"; then
  ok "Added $USER to plugdev (effective at next login or service restart)"
else
  warn "Could not add $USER to plugdev: rumble and the light bar will not work"
fi

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
ok "udev rules reloaded"

if [[ $DO_LOAD -eq 0 ]]; then
  echo
  ok "Installed but not loaded."
  echo "  Load it with: sudo modprobe $PAD_MOD"
  exit 0
fi

#########################################################################
#                              LOAD                                     #
#########################################################################

info "Loading $PAD_MOD"

echo
warn "THIS CHANGES THE GAMEPAD BUTTON MAP."
warn "hid-generic numbers buttons in HID descriptor order; $PAD_MOD maps them"
warn "semantically, so indices move. On a rover that means the e-stop button"
warn "moves, and an axis that rests at -1.0 can land on angular.z."
warn "Re-measure the map by pressing buttons before driving anything."
echo

sudo modprobe "$PAD_MOD" || fail "modprobe $PAD_MOD failed. Check: sudo dmesg | tail -20"
ok "$PAD_MOD loaded (an 'unsigned module' taint warning is expected)"

echo
info "Current pad state"
echo "  loaded:      $(lsmod | grep "^${PAD_MOD//-/_} " || echo 'not listed')"
echo "  bound to:    $(ls /sys/bus/hid/drivers/ 2>/dev/null | tr '\n' ' ')"
echo "  js devices:  $(ls /dev/input/js* 2>/dev/null | tr '\n' ' ' || echo none)"
echo "  pad on USB:  $(lsusb 2>/dev/null | grep -iE '054c|045e' || echo 'none on USB (Bluetooth pads will not appear here)')"

echo
ok "Done. Roll back at any time with: $0 --uninstall"

if [[ $KEEP_BUILD -eq 0 ]]; then
  echo "  Build artifacts kept in $BUILD_DIR (remove it by hand when finished)."
fi
