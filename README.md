# Rover Robotics ROS 2 Installation Scripts

Set up a Rover Robotics platform with ROS 2 by hand, one script at a time.
These scripts install ROS 2, clone and build the rover workspace, configure the
robot for its wheels and controller, install udev rules, and optionally create
a systemd service that starts the driver at boot.

---

## Before you begin

| | |
|---|---|
| **Operating system** | Ubuntu 22.04 (Jammy) or Ubuntu 24.04 (Noble) |
| **ROS 2** | Humble (on Jammy) or Jazzy (on Noble) |
| **Hardware** | Intel/AMD x86, Raspberry Pi, or NVIDIA Jetson (AGX Orin / Orin Nano). The installer detects which and adapts. |
| **Network** | Internet connection required |
| **Privileges** | A user with `sudo`. Do **not** run the scripts with `sudo`; they call it themselves where needed. |

```bash
git clone https://github.com/RoverRobotics/rover_install_scripts_ros2
cd rover_install_scripts_ros2
chmod +x *.sh
```

---

## Step 1: Install ROS 2

Optional: `setup_rover.sh` (Step 3) checks for ROS 2 and offers to install it.

| Ubuntu | ROS 2 | Driver branch used |
|---|---|---|
| 22.04 | Humble | `humble` |
| 24.04 | Jazzy | `jazzy` |

If ROS 2 is already installed, the installer uses it and the matching driver
branch. If both are installed, it uses the one that matches Ubuntu. If none is
installed, it offers to install the right one by running `ros2_installation.sh`
(desktop package set). Other Ubuntu releases are not supported.

To install ROS 2 on its own, for example to choose the smaller `base` package
set:

```bash
./ros2_installation.sh
```

You will be asked which distribution (Humble or Jazzy) and whether you want the
**desktop** or **base** package set. Pick `base` for a headless robot computer;
`desktop` adds RViz and the GUI tools.

<details>
<summary>Non-interactive options</summary>

```
-d, --distro SEL     1 or "humble" | 2 or "jazzy"
-p, --package SEL    1 or "desktop" | 2 or "base"
-y, --yes            Non-interactive apt
-f, --force          Install even if the Ubuntu release does not match
    --upgrade        Also run a full 'apt-get upgrade' first (off by default)
    --refresh-keys   Re-download the ROS keyring (fixes signature errors)
-h, --help           Show usage
```

```bash
./ros2_installation.sh -d humble -p base -y
```

`--upgrade` is off by default on purpose: on a Jetson a full upgrade can pull
in an L4T or kernel update you did not ask for.

</details>

---

## Step 2: Build the CAN kernel module (Jetson only)

**Only NVIDIA Jetson boards need this step.** Intel/AMD x86 machines and
Raspberry Pi already ship the `gs_usb` module in the stock Ubuntu kernel and
autoload it when the adapter is plugged in, so there is nothing to do.

The L4T/Tegra kernel does **not** ship `gs_usb`. Without it the USB-CAN adapter
enumerates as a USB device but never produces a CAN network interface, so the
rover looks dead on the bus.

```bash
./setup_jetson_can.sh
```

This builds `gs_usb` against the running kernel, installs the udev rule, and
sets up `can.service`. See
[Nvidia_Kernel_Mod_for_jetpack_6plus.pdf](docs/Nvidia_Kernel_Mod%20_for_jetpack_6plus.pdf)
for the background.

If you skip this step on a Jetson, `setup_rover.sh` will detect the missing
module and tell you.

---

## Step 3: Set up the rover

```bash
./setup_rover.sh
```

The installer walks you through four steps: robot, controller, components,
and a review screen. **Nothing is installed until you select Install on the
review screen**; Esc cancels at any point. If the ROS 2 distro installed on
the computer is the one the Ubuntu version calls for, it is used without asking.

### Robot model

`Mini 2WD`, `Mini (4WD)`, `Miti 65`, `Miti`, `Zero`, `Pro`, `Max`, `Mega`.

### MAX wheel size (MAX only)

MAX wheels come in two sizes the installer supports, each needing a different
config and URDF:

| Wheels | Config | Wheel radius |
|---|---|---|
| 13 inch | `max_130_config.yaml` | 0.155 m (calibrated effective radius; nominal 0.1651) |
| 15 inch | `max_150_config.yaml` | 0.1905 m |

The 6.5 inch and 10 inch variants are being phased out and are not offered by
the installer. Their configs (`max_65_config.yaml`, `max_100_config.yaml`) still
ship in `roverrobotics_ros2` if you need them. Point `max.launch.py` at one by
hand.

The installer sets both the config and the URDF in `max.launch.py` to match, and
points `max_teleop.launch.py` at the same config so the controller speed limits
in it apply.
Getting this wrong does not throw an error. It silently scales odometry and
commanded velocity by the ratio of the two wheel radii.

### Controller: PS4 or PS5

Every `*_teleop.launch.py` in `roverrobotics_ros2` ships pointed at
`ps4_controller.launch.py`. The installer repoints them at whichever pad you
select, so a PS5 (DualSense) works without hand-editing a launch file.

### Gamepad button/axis mapping

JetPack 6 (L4T R36.x) enumerates joystick axes and buttons differently from
JetPack 5 and from desktop Ubuntu, so the repo carries a `_jp6` variant of each
controller config. The installer detects JetPack 6 and defaults accordingly.

If your sticks and triggers come out swapped, re-run with the opposite choice:

```bash
./setup_rover.sh -r miti -g ps5 --jp6      # force the JetPack 6 map
./setup_rover.sh -r miti -g ps5 --no-jp6   # force the stock map
```

### Components

One checklist. Each item sets up everything it needs, including its services
and watchdogs, and nothing it does not.

| Item | Default | What it sets up |
|---|---|---|
| **Start the driver at boot** | off | `roverrobotics.service`, which launches the driver at boot, restarts it if it exits, and stops it gracefully so it brakes the motors |
| **USB-CAN adapter** (CAN robots only) | on | `rovercan` udev rule, `can.service`, `can-watchdog` (restarts CAN if the link drops) and `can-selftest`; see [CAN interface naming](#can-interface-naming) |
| **BNO055 IMU** | off | the IMU driver. With the driver starting at boot, also a serial flush before each start (`reset_bno055_usb.sh`), so a desynced IMU port cannot keep the driver in a restart loop |
| **Intel RealSense** | off | the librealsense SDK and ROS wrapper; see below |
| **Start the camera at boot** | off | `rover-realsense.service` with a boot delay and a USB reset, and `realsense-watchdog`, which restarts the camera if frames stop. Selects RealSense too |
| **RPLIDAR S2** | off | the lidar driver |
| **Udev rules** | on | stable `/dev` names for the ESCs, IMU, lidar and GPS |
| **Cyclone DDS** | off | switches ROS 2 from Fast DDS to Cyclone DDS in `~/.bashrc`, `/etc/environment` and the services. Recommended on JetPack 6, where Fast DDS has been seen to stop delivering messages shortly after start |

The BNO055 driver comes from `ssharma0704/bno055` branch `fix-startup-race`:
upstream `flynneva/bno055` plus a retry of the serial connect and sensor setup,
submitted upstream as flynneva/bno055 pull request 85. Upstream can exit at boot
before the IMU's serial port appears.

Installing a sensor driver does not switch it on by itself: set `active: true`
for that sensor in `roverrobotics_driver/config/accessories.yaml`, since
`accessories.launch.py` only starts a node whose `active` flag is true.

### Intel RealSense (optional)

How it installs depends on the computer:

| Platform | librealsense SDK | ROS wrapper |
|---|---|---|
| Intel/AMD x86, Raspberry Pi | prebuilt packages (`ros-$ROS_DISTRO-librealsense2`, falling back to Intel's apt repo), quick | `ros-$ROS_DISTRO-realsense2-camera` from apt |
| NVIDIA Jetson | built from source with CUDA when available; the longest step (see *Build speed* below) | `realsense-ros` built in your workspace |

Intel publishes no arm64 debs, which is why a Jetson has to build the SDK.

**Unplug the camera before the Jetson SDK build.** The installer says so and
waits. Plug it back in afterwards.

**Build speed.** Intel's build script compiles two files at a time. The
installer raises that to one job per CPU core, capped at one job per 2 GB of
RAM so a small Jetson does not run out of memory, and never below two. It prints
the number it chose, for example `building with 14 parallel jobs (14 cores,
122 GB RAM)`:

| Jetson | Jobs |
|---|---|
| AGX Thor (14 cores, 128 GB) | 14 |
| AGX Orin 64 GB (12 cores) | 12 |
| AGX Orin 32 GB / Orin NX 16 GB (8 cores) | 8 / 7 |
| Orin Nano 8 GB (6 cores) | 3 |
| 4 GB modules, or memory unreadable | 2 (Intel's default) |

With Intel's two jobs the SDK build took about 14 minutes on an AGX Thor and
about 45 minutes on older Jetsons.

**JetPack and CUDA on a Jetson.** If you choose RealSense on a Jetson that has no
CUDA, the installer asks whether to install NVIDIA JetPack and CUDA first
(`nvidia-jetpack` from the L4T apt source, then `nvidia-cuda-dev` if `nvcc` is
still missing, and the CUDA paths in `~/.bashrc`). With CUDA the SDK processes
camera images on the GPU; without it the build still works, for the CPU only.
The question is not asked when CUDA is already installed or the computer is not
a Jetson. For unattended installs use `--with-jetpack`; `--no-jetpack` never
installs it.

**Start the camera at boot** runs `reset_realsense_usb.sh` before every start,
power-cycling the camera over USB, after waiting 20 s at boot for USB to
enumerate it: a camera that is missing when the node starts is otherwise never
picked up. `realsense-watchdog.timer` checks every 20 s that frames are
arriving and restarts the camera if they are not. The resets need a `NOPASSWD`
sudoers entry, written to `/etc/sudoers.d/rover-realsense` and scoped to that
one script.

### While it installs

After you select Install the installer asks for your sudo password once and
keeps it valid until it finishes, so it never stops halfway for a password.

Each long step shows one live line instead of scrolling output:

```
[4/9]: Installing NVIDIA JetPack and CUDA   (12:41 elapsed)
  / Installing nvidia-jetpack  [########............]  43%  8:36 elapsed, about 11:24 left
```

- The **spinner** turns several times a second while the step runs. If it stops
  turning, the installer itself has stopped.
- The **bar and the time left** compare the elapsed time with how long that step
  usually takes. A step running past its usual time stays at 99% and says
  `taking longer than usual` rather than looking stuck.
- A finished step leaves `done: <step> (m:ss)`. A failed step prints
  `FAILED: <step>` in red, followed by the last 15 lines that step produced.
- The full output of every step is written to **`~/rover_setup.log`**.
- `[n/total]` counts the main steps, with the total time so far. The installer
  also prints an estimate of the whole install once you select Install.

**Waiting for apt.** Only one program can install packages at a time. Ubuntu's
automatic updates, and on JetPack 7 NVIDIA's own Docker setup after
`nvidia-jetpack`, can be installing at the same moment, and apt normally fails at
once with `Could not get lock`. For the length of the install the installer adds
`/etc/apt/apt.conf.d/90rover-installer-lock-wait`, so every apt command, including
the ones inside Intel's RealSense script, waits up to 10 minutes instead. The
file is removed when the installer exits, whether it finished, failed or was
cancelled.

Run without a terminal (for example `-y` with the output redirected to a file),
the installer prints a plain line when each step starts and ends instead of the
live line.

### CAN setup

Offered for every CAN-connected model (Mini, Miti, Miti 65, Max, Mega), and
ticked by default. See [CAN interface naming](#can-interface-naming) below.

<details>
<summary>Non-interactive options</summary>

```
-r, --robot TYPE     mini_2wd | mini | miti_65 | miti | zero | pro | max | mega
-w, --max-wheel IN   MAX wheel size in inches: 13 | 15
-g, --gamepad PAD    ps4 | ps5
-d, --distro NAME    ROS 2 distro (humble, jazzy)
    --with-service   Start the driver at boot
    --with-can       Set up the USB-CAN adapter (CAN robots; default yes)
    --no-can         Skip the CAN setup
    --with-imu       BNO055 IMU (serial flush before each start with --with-service)
    --with-lidar     RPLIDAR S2 driver
    --with-realsense Intel RealSense SDK and ROS wrapper
    --no-realsense   Skip RealSense without being asked
    --with-rs-service  Start the camera at boot, with watchdog (implies --with-realsense)
    --with-cyclone   Use Cyclone DDS (default: Fast DDS)
    --with-jetpack   Jetson + RealSense: install JetPack and CUDA if CUDA is missing
    --no-jetpack     Never install JetPack/CUDA
    --no-udev        Skip the udev rules
    --install-ros    Install the matching ROS 2 if it is missing (runs ros2_installation.sh)
    --jp6            Force the JetPack 6 gamepad mapping
    --no-jp6         Force the stock gamepad mapping
-y, --yes            Non-interactive
-h, --help           Show usage
```

```bash
./setup_rover.sh --robot miti --gamepad ps5 --with-service -y
./setup_rover.sh -r max -w 13 -g ps5 --with-imu -y
./setup_rover.sh -r miti -g ps5 --with-service --with-imu --with-rs-service --with-cyclone -y
```

`--yes` requires `--robot`, and `--robot max` also requires `--max-wheel`.
There is no safe default for either.

</details>

---

## CAN interface naming

Most M-series rovers (Mini, Miti, Max, Mega) connect over a USB-CAN adapter
(`1d50:606f`: CANable / candleLight / InnoMaker USB2CAN V3.3).

The kernel's `canN` names are **not stable**. On the Jetson AGX Orin the two
onboard `mttcan` controllers and the USB adapter race for `can0`/`can1`/`can2`
at boot: the same adapter can come up as `can2` on one boot and `can0` on the
next. Anything pinned to a `canN` name will, on some boots, bind to an onboard
controller with nothing wired to it. That interface comes up `UP` and
`ERROR-ACTIVE` and looks perfectly healthy, but carries no data, and the driver
logs `Did not receive any data from the robot`, indistinguishable from a
genuinely failed bus.

`udev/99-can-usb.rules` therefore binds the adapter to the fixed name
**`rovercan`** by USB vendor and product ID, and `setup_rover.sh` updates
`device_port` in the robot's config to match. The same name is used by
`enablecan`, `can-watchdog`, `setup_jetson_can.sh` and the driver config, so
everything agrees.

> **Note:** that config edit is local to your clone. Running `git pull` inside
> `~/rover_workspace/src/roverrobotics_ros2` reverts `device_port` to `can0`.
> Re-run `setup_rover.sh` afterwards, or re-apply it by hand.

The adapters used on these rovers support **classic CAN only**: not CAN-FD and
not `berr-reporting`. `enablecan` tries CAN-FD first and falls back, reporting
which mode it settled on.

---

## What gets installed

| Path | Purpose | Installed by |
|---|---|---|
| `~/rover_workspace/` | ROS 2 workspace and source repos | `setup_rover.sh` |
| `~/rover_setup.log` | Full output of every install step | `setup_rover.sh` |
| `/etc/udev/rules.d/55-roverrobotics.rules` | Stable `/dev` names for ESCs, IMU, LIDAR, GPS | `setup_rover.sh` |
| `/etc/udev/rules.d/99-can-usb.rules` | Renames the USB-CAN adapter to `rovercan` | both |
| `/etc/modules-load.d/gs_usb.conf` | Loads `gs_usb` at boot (Jetson only) | both |
| `/usr/sbin/enablecan` | Resets the adapter and brings the CAN link up | both |
| `/etc/systemd/system/can.service` | Runs `enablecan` at boot | both |
| `/usr/sbin/can-watchdog` + `.service` + `.timer` | Restarts `can.service` if the link drops | `setup_rover.sh` |
| `/usr/sbin/can-selftest` | Says whether a silent bus is the adapter or the rover | `setup_rover.sh` |
| `/usr/local/sbin/reset_realsense_usb.sh` | Power-cycles the camera over USB before each start | `setup_rover.sh` (RealSense service) |
| `/etc/sudoers.d/rover-realsense` | NOPASSWD for that one reset script | `setup_rover.sh` (RealSense service) |
| `/etc/systemd/system/rover-realsense.service` | Starts the camera node at boot | `setup_rover.sh` (RealSense service) |
| `/usr/sbin/realsense-watchdog` + `.service` + `.timer`, `/usr/local/sbin/realsense-probe` | Restarts the camera if frames stop | `setup_rover.sh` (RealSense service) |
| `/usr/local/sbin/reset_bno055_usb.sh`, `/etc/sudoers.d/rover-bno055` | Flushes the IMU serial port before each driver start | `setup_rover.sh` (IMU + driver at boot) |
| `/etc/environment`, `~/.bashrc` | `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` | `setup_rover.sh` (Cyclone DDS) |
| `/usr/sbin/roverrobotics` | Sources ROS and the workspace, launches the driver | `setup_rover.sh` |
| `/etc/systemd/system/roverrobotics.service` | Starts the driver at boot | `setup_rover.sh` |

---

## Verify the install

```bash
source ~/rover_workspace/install/setup.bash
```

**CAN bus.** Expect `UP` and `ERROR-ACTIVE`, and traffic from the VESCs:

```bash
ip -details link show rovercan
candump rovercan
```

If the interface is up but `candump` shows nothing, run the self-test rather
than guessing:

```bash
sudo can-selftest
```

It puts the adapter into loopback, where it transmits to itself and needs no
rover, no VESCs and no wiring. If the frame comes back the adapter is fine and
the problem is rover power, the cable or termination. If it does not, the
adapter itself is wedged. The test restores normal mode when it finishes.

**Driver.** Launch it by hand:

```bash
ros2 launch roverrobotics_driver miti_teleop.launch.py
```

**Odometry.** Expect a steady rate:

```bash
ros2 topic hz /odometry/wheels
```

**Gamepad.** Expect axis values to change as you move the sticks:

```bash
ros2 topic echo /joy
```

**Camera** (if installed):

```bash
ros2 topic hz /camera/camera/color/image_raw
realsense-viewer          # Jetson source build only
```

**Services**:

```bash
systemctl status can.service roverrobotics.service rover-realsense.service
journalctl -u roverrobotics.service -f
```

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `rovercan` does not exist | udev rename has not run since the adapter was plugged in | Unplug/replug the adapter, or reboot |
| `rovercan` does not exist, Jetson | `gs_usb` not built for the L4T kernel | Run `./setup_jetson_can.sh` |
| `rovercan` does not exist, x86 or Pi | Module missing from the kernel | `sudo apt-get install linux-modules-extra-$(uname -r)` |
| Interface is up but `candump` is silent | Adapter wedged, or rover unpowered | `sudo can-selftest` tells you which |
| Adapter works, then dies after every reboot | Some boards wedge on a warm reboot | See **USB-CAN adapters that need a replug** below |
| Bus worked, then went silent mid-run | Adapter knocked loose | `can-watchdog.timer` re-runs `can.service` every 30 s; see `journalctl -u can-watchdog` |
| `Did not receive any data from the robot` | Same as above | Same as above |
| `RTNETLINK answers: Operation not supported` | CAN-FD options on a classic-CAN adapter | Expected; `enablecan` falls back automatically |
| Sticks and triggers swapped | Wrong gamepad map for this kernel | Re-run with `--jp6` or `--no-jp6` |
| Controller does nothing | Teleop launch pointed at the other pad | Re-run with `-g ps4` or `-g ps5` |
| Odometry distance is consistently off | Wrong MAX wheel size | Re-run with `-w 13` or `-w 15` |
| Driver dies at boot, works by hand | Driver started before the CAN bus | `journalctl -u roverrobotics.service`; the unit is ordered `After=can.service` and retries every 5 s |
| Wheels keep turning for about a second after the service stops | Unit installed by an older `setup_rover.sh`, without the graceful-stop settings | Re-run `./setup_rover.sh --with-service`; the unit now sets `KillMode=mixed`, `KillSignal=SIGINT`, `TimeoutStopSec=15`, so the driver can brake the motors as it exits |
| Wheels coast for about a second after the driver crashes | A hard crash or `kill -9` cannot send the brake; the VESCs hold the last command until their own timeout, then release | In VESC Tool, set a *Timeout Brake Current* on each VESC so it brakes instead of coasting when commands stop |
| `UnicodeDecodeError` from colcon or rosdep | Non-UTF-8 locale | Re-run `./ros2_installation.sh`, which configures the locale |
| `apt update` signature error | Stale ROS keyring | `./ros2_installation.sh --refresh-keys` |
| A step shows `FAILED` | See the lines printed under it | The whole output of that step is in `~/rover_setup.log` |
| A step sits at 99%, `taking longer than usual` | Slow download or a slower computer, not a hang while the spinner turns | Wait; check `tail -f ~/rover_setup.log` in a second terminal to watch it |
| udev `/dev` symlinks missing | `setserial` not installed | Re-run `./setup_rover.sh`; it is in the package list |
| Camera node starts then dies repeatedly | D435i USB enumeration failure | `rover-realsense.service` power-cycles it each start; check `journalctl -u rover-realsense` |
| `librealsense2` has no install candidate | Intel publishes no build for this Ubuntu release | Build from source, or use a release Intel supports |
| Sensor installed but no topics | `active: false` in `accessories.yaml` | Set `active: true` for that sensor and rebuild |

After changing a config or updating the driver, restart the service instead of
rebooting:

```bash
sudo systemctl restart roverrobotics.service
```

---

## Re-running and updating

All scripts are safe to re-run. `setup_rover.sh` updates an existing clone in
place with `git pull --ff-only` rather than failing, and re-applies the CAN
name, wheel size, controller and gamepad map every time, so re-running after a
`git pull` is the supported way to restore them.

Anything patched into the source tree is applied **before** `colcon build`. If
you edit a launch file or config by hand afterwards, rebuild:

```bash
cd ~/rover_workspace && colcon build
```

---

## Uninstall

```bash
./uninstall_rover_script.sh
```

With no options it removes everything `setup_rover.sh` set up on the system:
every service and watchdog (driver, CAN, camera), the helper scripts, the
sudoers entries, the udev rules, the `gs_usb` module config, the Cyclone DDS
setting, the install log and the workspace line in `~/.bashrc`. It keeps your
workspace, ROS 2 and the NVIDIA software.

To remove more, add any of these. Each one asks before it removes anything,
unless you add `-y`:

| Option | Also removes |
|---|---|
| `--workspace` | `~/rover_workspace` (source, build and install) |
| `--realsense` | the librealsense SDK: on a Jetson the files built into `/usr/local`, its udev rules and build files; on x86 the prebuilt packages and Intel's apt source |
| `--ros` | ROS 2: every `ros-<distro>-*` package, colcon and rosdep, the ROS apt source and keyring, and the ROS lines in `~/.bashrc` |
| `--jetpack` | NVIDIA JetPack and CUDA (`nvidia-jetpack` and everything it brought in) and the CUDA lines in `~/.bashrc`. The L4T packages the Jetson boots from are never removed |
| `--docker` | Docker, which JetPack 7 installs, and its apt source |
| `--all` | all of the above: the computer as it was before `ros2_installation.sh` and `setup_rover.sh` |

```bash
./uninstall_rover_script.sh --workspace --realsense   # start the rover setup over, keep ROS and CUDA
./uninstall_rover_script.sh --all                     # back to a bare computer
```

Reboot afterwards. Packages the installer added that other software may also use,
such as build tools and system libraries, are left in place; only packages that
nothing needs any more are removed (`apt-get autoremove`). When it removes
packages it also clears their leftover configuration and the apt download cache,
which holds several GB after JetPack and ROS.

---

## USB-CAN adapters that need a replug

Not all `1d50:606f` adapters behave the same. Some boards come back cleanly
from a warm reboot; others enumerate, bind to `gs_usb` and bring the interface
`UP`, but their CAN core stays dead until the module is physically unplugged
and plugged back in.

A **canable.io CANable** was measured in this state on a Jetson AGX Orin
(L4T R39). It failed loopback, meaning it could not receive even its own
frames, so the fault was in the adapter rather than the bus. None of the
following recovered it:

- toggling `/sys/bus/usb/devices/<dev>/authorized`
- `usbreset` (USBDEVFS_RESET port-reset signalling)
- unbinding and rebinding the `gs_usb` driver
- unbinding and rebinding the USB device, forcing full re-enumeration
- reloading the `gs_usb` kernel module
- rebinding the parent hub
- cutting the port's VBUS with `uhubctl` (port status confirmed `off`)

Only a physical replug cleared it. If your adapter behaves this way, either
reflash its firmware (these boards expose a DFU interface) or use one that
survives a reboot. The **InnoMaker USB2CAN V3.3** does.

`sudo can-selftest` identifies the condition in about two seconds instead of
sending you looking at cables.

---

## Known limitations

- The `_neo` URDF variants (`max_130_neo`, `max_150_neo`, `miti_neo`) are a different chassis, not a different wheel size. The installer does not select them; set them by hand in the launch file if you have that chassis.
- MAX 6.5 inch and 10 inch are being phased out and are not selectable. Their configs still ship upstream.
- `device_port`, the MAX wheel size and the controller choice are edits to your local clone of `roverrobotics_ros2`. A `git pull` reverts them.

---

## Need help?

Check the [Rover Robotics documentation](https://roverrobotics.com) or open a
discussion on [GitHub](https://github.com/RoverRobotics).
