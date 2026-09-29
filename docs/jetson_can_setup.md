# Jetson CAN Setup - Beginner's Guide

This guide walks you through setting up the USB-CAN adapter on a fresh NVIDIA Jetson
so that it can talk to the VESC motor controller. If you follow every step in order,
it will work. No prior knowledge of Linux kernels, udev, or systemd is required - just
the ability to copy-paste commands into a terminal.

**Estimated time:** 20-30 minutes.

---

## What we are doing and why

The Jetson's stock Ubuntu install does not come with a driver for the USB-CAN adapter
we use (brand: Geschwister Schneider / candleLight / InnoMaker, USB ID `1d50:606f`).
Without this driver, plugging the adapter into the Jetson does nothing - the operating
system doesn't know what it is.

We will:

1. Build the missing driver ourselves (it's called `gs_usb`).
2. Install it into the system so it loads every time the Jetson boots.
3. Tell the system to give the adapter a friendly, stable name (`rovercan`) so your
   robot code can find it reliably, no matter which USB port you use.
4. Tell the system to automatically turn the CAN connection ON at boot.
5. Point the robot software at the new name.

At the end, you will plug in the USB-CAN adapter, power on the Jetson, and everything
will just work.

---

## Before you start

You need:

- A Jetson running L4T R36.x (JetPack 6) with kernel version `5.15.x-tegra`. If you
  have a different Jetson (older JetPack / different kernel), the driver source
  version in **Step 2** below needs to change - see the "Other kernel versions" box.
- The Jetson connected to the internet (to download the driver source).
- The USB-CAN adapter itself. Do not plug it in yet.
- The VESC already wired to the USB-CAN adapter (CAN-H to CAN-H, CAN-L to CAN-L,
  with proper 120-ohm termination on the bus).
- The `rover_install_scripts_ros2` repository cloned into your home directory, i.e.
  `/home/rover/rover_install_scripts_ros2/` exists. It contains some files this guide
  copy into system locations.

---

## How to open a terminal

Press `Ctrl + Alt + T`. A black window will appear with a prompt like:

```
rover@ubuntu:~$
```

Everything in this guide is typed into that terminal. To paste something from this
document into the terminal, use `Ctrl + Shift + V` (regular `Ctrl + V` does not work
in most terminals).

When a step says "run this command", select the text, copy it, paste into the
terminal, and press `Enter`.

---

## A note about `sudo` and passwords

Many commands below start with `sudo`. This is Linux's way of saying "do this as the
administrator". The first time you use `sudo` in a terminal session, it will ask for
your password. Type it (you will not see any characters appear as you type - this is
normal) and press `Enter`. It will remember the password for about 5 minutes, so you
won't have to type it every single command.

---

## Step 1 - Verify your system is the right one

Run these three commands, one at a time, and check the output:

```bash
uname -r
```

You should see something like `5.15.185-tegra`. Note down your exact version - we will
need it later. If the version starts with a different number like `6.8` or `4.9`,
**stop** and read the "Other kernel versions" box under Step 2 before continuing.

```bash
cat /etc/nv_tegra_release
```

The first line should mention `R36` (or similar). This confirms it is a Jetson running
NVIDIA L4T, not some other ARM computer.

```bash
zcat /proc/config.gz | grep CAN_GS_USB
```

You should see exactly this:

```
# CONFIG_CAN_GS_USB is not set
```

This confirms the driver is missing and we need to build it. If the output instead
says `CONFIG_CAN_GS_USB=y` or `=m`, the driver is already in the system and you can
skip to **Step 6** (udev rule).

Also verify the Linux kernel headers are installed (we need them to build the driver):

```bash
ls /lib/modules/$(uname -r)/build
```

You should see a directory listing (lots of files). If instead you see
`No such file or directory`, install the headers:

```bash
sudo apt install nvidia-l4t-kernel-headers
```

---

## Step 2 - Download the driver source code

We need one single C source file that contains the entire driver. It comes from the
official Linux kernel repository. The version of the source **must match the major +
minor part of your kernel**. For a `5.15.x-tegra` kernel, use the `v5.15` tag.

Make a workspace and download the file:

```bash
mkdir -p ~/gs_usb_build
cd ~/gs_usb_build
wget https://raw.githubusercontent.com/torvalds/linux/v5.15/drivers/net/can/usb/gs_usb.c
```

After it finishes, run `ls` and you should see `gs_usb.c` listed. It's about 25 KB.

> **Other kernel versions**
> - If `uname -r` said `6.8.x-tegra`, change `v5.15` above to `v6.8`.
> - If you got a different kernel major.minor, use that version tag.
> - Source code lives in the Linux github: https://github.com/torvalds/linux - >   click "tags", find your version, then navigate to `drivers/net/can/usb/gs_usb.c`.

---

## Step 3 - Build the driver

A "build" means turning the source code (`.c`) into a loadable binary (`.ko`) that
the kernel can use. To do this we need a small file called a `Makefile` that tells
the build system what to compile.

Create the Makefile by pasting this **entire block** into the terminal at once and
pressing Enter (do not reformat it - the spacing must be tabs):

```bash
cd ~/gs_usb_build
printf 'obj-m := gs_usb.o\nKDIR := /lib/modules/$(shell uname -r)/build\nPWD := $(shell pwd)\n\nall:\n\t$(MAKE) -C $(KDIR) M=$(PWD) modules\n\nclean:\n\t$(MAKE) -C $(KDIR) M=$(PWD) clean\n' > Makefile
```

Now compile:

```bash
make
```

This will run for a few seconds. You will see several `CC` and `LD` lines scroll past.
At the end, if you see **no errors**, it worked.

A single warning like `the compiler differs from the one used to build the kernel`
is **harmless** - ignore it.

Verify the output file was created:

```bash
ls -la gs_usb.ko
```

You should see `gs_usb.ko` listed, about 100 KB in size.

**If this step fails with compile errors**, the most likely cause is that the source
version doesn't match your kernel. Go back to Step 2 and try a closer version tag.

---

## Step 4 - Install and load the driver

"Install" means copying the `.ko` file to a special directory so the kernel knows
where to find it. "Load" means actually activating it right now.

```bash
sudo mkdir -p /lib/modules/$(uname -r)/updates
sudo cp ~/gs_usb_build/gs_usb.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a
```

The `depmod` command rebuilds the kernel's internal list of available modules so it
knows about our new one.

Now load it:

```bash
sudo modprobe gs_usb
```

You will see a warning:

```
module verification failed: signature and/or required key missing - tainting kernel
```

This is **completely normal and harmless**. It just means the driver isn't
cryptographically signed (only drivers shipped by NVIDIA are). The driver will still
work.

Verify the driver is loaded:

```bash
lsmod | grep gs_usb
```

You should see:

```
gs_usb                 24576  0
can_dev                36864  2 mttcan,gs_usb
```

If you see those two lines, the driver is loaded successfully.

---

## Step 5 - Plug in the USB-CAN adapter and confirm it is detected

Now plug the USB-CAN adapter into one of the Jetson's USB ports. Wait about 3 seconds.

Check that Linux sees it:

```bash
lsusb | grep 1d50
```

You should see a line like:

```
Bus 001 Device 006: ID 1d50:606f OpenMoko, Inc. Geschwister Schneider CAN adapter
```

If you don't see that line, try a different USB port, or check the LED on the adapter
(it should light up when plugged in).

Now check that it shows up as a CAN network interface:

```bash
ip -br link show type can
```

You should see multiple `canN` lines. One of them is the USB adapter, another is the
Jetson's built-in on-chip CAN (which we are not using). To find which one is the USB
adapter, run:

```bash
for i in {0..4}; do
  driver=$(readlink /sys/class/net/can$i/device/driver 2>/dev/null | xargs basename 2>/dev/null)
  echo "can$i: $driver"
done
```

The one that says `gs_usb` is the USB adapter. The ones that say `mttcan` are the
Jetson's built-in CAN ports (not used).

**Important:** the number the USB adapter gets (`can0`, `can1`, etc.) can change
between reboots, which is exactly why we need the next step.

---

## Step 6 - Install the udev rule for a stable name

A "udev rule" is a tiny instruction that tells Linux: "every time you see this
specific USB device, rename its interface to `rovercan`". This way, no matter what
number the kernel assigns, our robot code always finds it at `rovercan`.

The rule file already exists in your scripts repo at
`~/rover_install_scripts_ros2/udev/99-can-usb.rules`. Copy it into the system
location:

```bash
sudo cp /home/rover/rover_install_scripts_ros2/udev/99-can-usb.rules /etc/udev/rules.d/99-can-usb.rules
sudo udevadm control --reload-rules
```

Now **unplug** the USB-CAN adapter, wait 3 seconds, and **plug it back in**. This is
required - the rule only takes effect on a fresh plug-in event.

After plugging back in, verify the rename worked:

```bash
ip -br link show type can
```

You should now see a line like:

```
rovercan          DOWN           <NOARP,ECHO>
```

(DOWN because we haven't turned it on yet - Step 7 does that.)

If you see `rovercan` in the list, the rule is working.

**If you still see `canN` with a number instead of `rovercan`**, the rule didn't match.
Check that the adapter's USB ID is `1d50:606f` (Step 5). If it is a different ID, open
the rule file, change the `idVendor` and `idProduct` values to match, and reinstall.

---

## Step 7 - Install the boot-time startup script

This is the script that runs automatically at every boot to turn the CAN link ON.

The stock Jetson ships with a buggy version of this script. We need to replace it with
a corrected one. Open a text editor with this command:

```bash
sudo nano /usr/sbin/enablecan
```

You'll see either existing content or an empty file. **Delete everything** (hold
`Ctrl + K` to cut lines, press it repeatedly to clear the file) and paste in exactly
this:

```bash
#!/bin/bash
set -e
IFACE=rovercan
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

Save and exit: press `Ctrl + O`, then `Enter` to confirm the filename, then `Ctrl + X`
to exit.

Make the script executable:

```bash
sudo chmod +x /usr/sbin/enablecan
```

What this script does, in plain English:
- Waits up to 15 seconds for `rovercan` to appear (the USB adapter might take a moment
  to be detected at boot).
- Brings the interface DOWN first (required before you can change settings).
- Sets the speed to 500 kbps (matches the VESC's default CAN speed).
- Turns the interface ON.

---

## Step 8 - Install and enable the startup service

A "service" in Linux is a program that runs automatically in the background. We need
to tell the system: "at every boot, run the `enablecan` script we just wrote in
Step 7". We do this by creating a service file.

Open a text editor to create the service file:

```bash
sudo nano /etc/systemd/system/can.service
```

**Delete anything that is already there** (if the file existed) and paste in exactly
this:

```ini
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
```

Save and exit: `Ctrl + O`, `Enter`, `Ctrl + X`.

What each part means, briefly:
- `ExecStart=/usr/sbin/enablecan` - run the script we made in Step 7.
- `Type=oneshot` + `RemainAfterExit=true` - the script runs once at boot, then exits;
  the system considers the service "active" after it succeeds.
- `After=network.target` - wait until basic networking is ready before running.
- `Restart=on-failure` - if the script fails (for example, the USB adapter isn't
  detected yet), systemd will try again.
- `WantedBy=multi-user.target` - run this on every normal boot.

Now tell systemd we added a new service, then enable it (so it runs at boot) and
start it right now:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now can.service
```

Check that it ran successfully:

```bash
systemctl status can.service --no-pager
```

You should see `Active: active (exited)` and `status=0/SUCCESS`. If instead you see
`failed`, jump to the **Troubleshooting** section at the end.

Now confirm the CAN interface is fully up:

```bash
ip -br link show rovercan
```

The expected output is:

```
rovercan          UP             <NOARP,UP,LOWER_UP,ECHO>
```

The key word is `LOWER_UP` - that means the VESC on the other end of the wire is
acknowledging frames. If you only see `UP` without `LOWER_UP`, the adapter is on but
nothing is answering - check your VESC power and wiring.

---

## Step 9 - Point your robot config at `rovercan`

The robot driver software reads a config file to know which interface to talk to.
Edit the config for your specific robot model. For a Miti rover:

```bash
nano ~/rover_workspace/src/roverrobotics_ros2/roverrobotics_driver/config/miti_config.yaml
```

Find the line that says `device_port:` and change its value to `rovercan`:

```yaml
device_port: "rovercan"
```

Save (`Ctrl + O`, `Enter`) and exit (`Ctrl + X`).

If you run a different robot model, edit its config file instead:
`max_100_config.yaml`, `max_130_config.yaml`, etc.

Rebuild the ROS workspace so the change takes effect:

```bash
cd ~/rover_workspace
colcon build --symlink-install
```

---

## Step 10 - Reboot and verify everything comes up on its own

This is the final test. Reboot:

```bash
sudo reboot
```

Wait for the Jetson to come back up, log in, open a new terminal, and run:

```bash
ip -br link show rovercan
```

You should see `rovercan UP <NOARP,UP,LOWER_UP,ECHO>` without having to run anything
manually.

Optionally, sniff some CAN traffic to confirm the VESC is talking:

```bash
sudo apt install can-utils  # only needed once, if not already installed
candump rovercan
```

You should see a stream of messages scrolling by - motor controller telemetry.
Press `Ctrl + C` to stop.

**If that works, you are done.** The setup will survive every reboot from now on.

---

## Troubleshooting

### "modprobe: FATAL: Module gs_usb not found" after a reboot

Cause: a kernel upgrade changed `uname -r` and the old `.ko` no longer matches.

Fix: rebuild and reinstall:

```bash
cd ~/gs_usb_build
make clean
make
sudo cp gs_usb.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a
sudo modprobe gs_usb
```

**Prevention:** freeze the kernel version so `apt upgrade` can't change it:

```bash
sudo apt-mark hold nvidia-l4t-kernel nvidia-l4t-kernel-headers
```

To unfreeze later, replace `hold` with `unhold`.

### `can.service` is in "failed" state after boot

Look at the error:

```bash
journalctl -u can.service --no-pager | tail -30
```

Common causes:

- **"rovercan not found after 15s"** - the udev rule isn't renaming the interface.
  Check Step 6 worked. Run `ip -br link show type can` - if you only see numbered
  `canN` with no `rovercan`, unplug and replug the adapter; if it still doesn't
  rename, check that `/etc/udev/rules.d/99-can-usb.rules` exists and the USB ID in
  it matches your adapter's ID from `lsusb`.

- **"Device or resource busy"** - the interface was already UP when the script tried
  to reconfigure it. This should not happen with the Step 7 script, which brings the
  link DOWN first. If you see it, make sure you actually pasted the **exact** script
  from Step 7.

### `rovercan` shows `UP` but not `LOWER_UP`

`UP` means the driver is active; `LOWER_UP` means something on the bus is answering.
If you only see `UP`:

- Check the VESC is powered on.
- Check CAN-H and CAN-L are wired correctly and not swapped.
- Check the 120-ohm termination resistor is in place at both ends of the CAN bus.
- Verify the VESC is configured for 500 kbps classic CAN (not CAN-FD) in VESC Tool.

### You want to swap in a different USB-CAN adapter

If the new adapter also has USB ID `1d50:606f` (most CANable / candleLight /
InnoMaker adapters do), just unplug the old one and plug in the new one - no config
change needed.

If the new adapter has a different USB ID (check with `lsusb`), edit the rule file
`/etc/udev/rules.d/99-can-usb.rules` and change `1d50` / `606f` to the new values.
Then `sudo udevadm control --reload-rules` and replug.

### Your CAN bus runs at a different speed (not 500 kbps)

Open `/usr/sbin/enablecan` (Step 7) and change `500000` to your bus speed. Common
values: `125000`, `250000`, `500000`, `1000000`.
