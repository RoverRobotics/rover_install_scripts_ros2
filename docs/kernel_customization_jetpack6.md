# JetPack 6.2 Kernel Customization for USB-CAN and Gamepads

Builds a JetPack 6.2 (L4T R36.4.3) kernel with the USB-CAN and gamepad drivers compiled
in, then flashes it to the Jetson. The result is a kernel image that carries them from
the first boot, which is what you want when you are producing a base image.

**Estimated time:** 2-4 hours, most of it downloading and compiling.

---

## Read this first: you probably do not need this procedure

On a Jetson that is already running, **do not do this.** Use the scripts instead:

```bash
./setup_jetson_can.sh        # USB-CAN
./setup_jetson_gamepad.sh    # PS4/PS5 controller
```

They build the same drivers as out-of-tree kernel modules against the kernel already on
the robot, install them, write the udev rules and set up the services. Each takes about a
minute, needs no reflash, and leaves the rest of the system untouched. Both have been
verified on JetPack 6 (5.15.x-tegra) and JetPack 7 (6.8.x-tegra).

A full reflash wipes the robot: services, workspace, network configuration, everything.

Use the procedure below only when you are building an image from scratch, or when you
specifically want the driver inside the kernel image rather than loaded as a module.

---

## What you need

- An x86_64 Ubuntu host to cross-compile on. This does not run on the Jetson.
- The Jetson in recovery mode when you reach the flashing step.
- Roughly 60 GB of free disk space on the host.

## 1. Fetch the BSP and sources

Create the working folder:

```bash
mkdir -p ~/can_kernel_jetpack
cd ~/can_kernel_jetpack
```

From <https://developer.nvidia.com/embedded/jetson-linux-r3643> download:

- Driver Package (BSP)
- Sample Root Filesystem
- Driver Package (BSP) Sources

Then unpack and prepare the rootfs:

```bash
tar xf Jetson_Linux_R36.4.3_aarch64.tbz2
sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_R36.4.3_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
cd Linux_for_Tegra/
sudo ./tools/l4t_flash_prerequisites.sh
sudo apt-get install qemu-user-static
sudo ./apply_binaries.sh
```

Unpack the kernel sources:

```bash
mkdir -p ~/can_kernel_jetpack/src
cd ~/can_kernel_jetpack
tar xf public_sources.tbz2 -C ~/can_kernel_jetpack/src

cd ~/can_kernel_jetpack/src/Linux_for_Tegra/source
tar xf kernel_src.tbz2
tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2
```

## 2. Enable the driver in the kernel config

```bash
cd ~/can_kernel_jetpack/src/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/
```

Add the following to **both** `defconfig` and `tegra_prod_defconfig`.

USB-CAN:

```
CONFIG_CAN_GS_USB=y
```

Gamepads, if you want controller support in the image as well:

```
# PS4 (DualShock 4): on 5.15 this is hid-sony, NOT hid-playstation
CONFIG_HID_SONY=m
CONFIG_SONY_FF=y
# PS5 (DualSense): hid-playstation on 5.15 handles the DualSense only
CONFIG_HID_PLAYSTATION=m
CONFIG_PLAYSTATION_FF=y
# Xbox USB: xpad is already =m, add rumble + LEDs
CONFIG_JOYSTICK_XPAD_FF=y
CONFIG_JOYSTICK_XPAD_LEDS=y
# Steam controller
CONFIG_HID_STEAM=m
# Logitech wireless pads (F710 etc.); HID_LOGITECH is already =y
CONFIG_HID_LOGITECH_DJ=m
CONFIG_HID_LOGITECH_HIDPP=m
CONFIG_LOGITECH_FF=y
# Generic and third-party rumble pads
CONFIG_HID_BETOP_FF=m
CONFIG_HID_DRAGONRISE=m
CONFIG_DRAGONRISE_FF=y
CONFIG_HID_GREENASIA=m
CONFIG_GREENASIA_FF=y
CONFIG_HID_SMARTJOYPLUS=m
CONFIG_SMARTJOYPLUS_FF=y
CONFIG_HID_ZEROPLUS=m
CONFIG_ZEROPLUS_FF=y
CONFIG_HID_THRUSTMASTER=m
CONFIG_THRUSTMASTER_FF=y
CONFIG_HID_EMS_FF=m
CONFIG_HID_MAYFLASH=m
CONFIG_HID_WIIMOTE=m
# Virtual input devices (needed by tools like ds4drv / Steam Input)
CONFIG_INPUT_UINPUT=m
```

> **`CONFIG_CAN_GS_USB=y` is written as built-in but the driver is a `tristate`, and a
> build of this defconfig produces `gs_usb` as a module.** That is why the
> `modules-load.d` step further down is needed at all - a genuinely built-in driver would
> not need it.

> **The PS4 driver is different on this kernel.** On 5.15 the DualShock 4 binds to
> `hid-sony`; `hid-playstation` exists but covers the DualSense only. From 6.8 onwards
> that ownership moves to `hid-playstation` and `hid-sony` handles PS3 pads. If you are
> looking at the JetPack 7 version of this document, its comments say the opposite for
> exactly that reason - do not copy that config block onto a 5.15 kernel.

> **Five symbols from the JetPack 7 list do not exist in 5.15** and are deliberately
> absent above: `HID_NINTENDO`, `NINTENDO_FF`, `STEAM_FF`, `HID_GOOGLE_STADIA_FF` and
> `HID_PXRC`. Kconfig ignores symbols it does not know, so adding them produces no error
> and no driver - you would simply believe you had Switch Pro or Stadia support and not
> have it.

## 3. Install build dependencies and the toolchain

```bash
sudo apt install flex bison libssl-dev git-core build-essential bc sshpass abootimg nfs-kernel-server
```

Only if you are building a real-time kernel, from
`~/can_kernel_jetpack/src/Linux_for_Tegra/source`:

```bash
./generic_rt_build.sh "enable"
```

Download the Bootlin toolchain (gcc 11.3) linked from
<https://developer.nvidia.com/embedded/jetson-linux>, then:

```bash
mkdir $HOME/l4t-gcc
cd $HOME/l4t-gcc
tar xf aarch64--glibc--stable-2022.08-1.tar.bz2
```

## 4. Build the kernel

From `~/can_kernel_jetpack/src/Linux_for_Tegra/source`:

```bash
export CROSS_COMPILE=$HOME/l4t-gcc/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
make -C kernel
export INSTALL_MOD_PATH=~/can_kernel_jetpack/Linux_for_Tegra/rootfs/
sudo -E make install -C kernel
cp kernel/kernel-jammy-src/arch/arm64/boot/Image ~/can_kernel_jetpack/Linux_for_Tegra/kernel/Image
```

## 5. Build the out-of-tree modules

```bash
cd ~/can_kernel_jetpack/src/Linux_for_Tegra/source/
```

Only if you are **not** building a real-time kernel:

```bash
export IGNORE_PREEMPT_RT_PRESENCE=1
```

Then:

```bash
export CROSS_COMPILE=$HOME/l4t-gcc/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src
make modules
export INSTALL_MOD_PATH=~/can_kernel_jetpack/Linux_for_Tegra/rootfs/
sudo -E make modules_install
```

## 6. Update the initrd and flash

```bash
cd ~/can_kernel_jetpack/Linux_for_Tegra
sudo ./tools/l4t_update_initrd.sh
```

Put the Jetson in **recovery mode** before flashing. Pick the flashing target that matches
your board - see
<https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/IN/QuickStart.html>.

Orin Nano devkit, NVMe:

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 jetson-orin-nano-devkit internal
```

Orin Nano devkit with Super Configuration, SD card:

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device mmcblk0p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 jetson-orin-nano-devkit-super internal
```

AGX Orin, NVMe:

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --external-device nvme0n1p1 \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  --showlogs --network usb0 jetson-agx-orin-devkit external
```

---

## After flashing: every Jetson board

Clone this repository onto the Jetson and run the main installer:

```bash
./setup_rover.sh
```

It is interactive, and its CAN step installs the udev rule that gives the adapter the
stable name `rovercan`, plus `/usr/sbin/enablecan`, `can.service`, `can-watchdog` and
`can-selftest`. Do this rather than writing those files by hand - a hand-written setup
usually leaves out the udev rule.

`setup_rover.sh` configures CAN but does not build the driver, so it checks for it first.
On an image produced by this document the driver is already in the kernel and it will
report `gs_usb kernel module available`. On a stock L4T kernel it stops and tells you to
run `./setup_jetson_can.sh` first, which builds `gs_usb` as a module.

The controller works the same way: `setup_rover.sh` sets the pad map and udev rules but
does not build the pad driver. If you added the gamepad options above you need nothing
further. Otherwise run `./setup_jetson_gamepad.sh`, which builds it as a module and exits
without doing anything if the kernel already provides it.

> **Note on interface naming.** Older versions of this document told you to change `can0`
> to `can2` in the install scripts on an AGX Orin, because the onboard CAN controllers
> take the low numbers. That is no longer necessary. `setup_rover.sh` and
> `setup_jetson_can.sh` install a udev rule that binds the adapter by USB VID:PID
> (`1d50:606f`) and names it `rovercan`, so the kernel's `canN` ordering does not matter.

## After flashing a SEED NX

A SEED NX ships without WiFi drivers or modules installed.

```bash
sudo apt update
sudo apt upgrade
```

With no WiFi driver, connect over ethernet. On the host, set the wired connection's IPv4
and IPv6 to "shared to other computers".

```bash
sudo apt install snap
sudo snap install firefox
sudo apt install backport-iwlwifi-dkms
```

Then clone this repository and run `./setup_rover.sh` as above. It installs ROS 2 for you
if it is missing - `--install-ros` skips the prompt and runs `ros2_installation.sh`.

---

## Reference

- [Jetson Linux R36.4.3 downloads](https://developer.nvidia.com/embedded/jetson-linux-r3643)
- [Flashing quick start](https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/IN/QuickStart.html)
- [Kernel customization](https://docs.nvidia.com/jetson/archives/r36.4/DeveloperGuide/SD/Kernel/KernelCustomization.html)
- [Jetson Linux downloads index](https://developer.nvidia.com/embedded/jetson-linux)
