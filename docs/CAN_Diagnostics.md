# CAN Diagnostics

Rover Robotics. For rovers driving four VESC motor controllers over a USB-CAN adapter on
SocketCAN with the `roverrobotics` ROS 2 driver. MITI, Mini, MAX and Mega.

Work through it in order. Section 1 first: two of the obvious things to try destroy the
evidence. Expected outputs are from a healthy AGX Orin MITI.

---

## 1. Before you touch the robot

**Wheels off the ground, and stop the driver before touching any CAN connector.** A VESC
holds its last duty until its own timeout, and while the bus is down the driver keeps
queueing writes it cannot send. They are delivered the moment the bus returns, so a
robot can move when a cable is reseated.

    sudo systemctl stop roverrobotics.service

or at minimum `sudo ip link set rovercan down; sudo ip link set rovercan up` to flush
the queue.

**Do not power-cycle yet.** The VESC fault log is volatile and a power cycle erases it.
It is the best evidence on the machine, so read it first, section 7. Ignore the one DRV
fault logged at about 21 V on every power-up.

**Do not warm-reboot first.** A warm reboot can wedge the adapter in a state no software
recovers, turning an intermittent fault into a permanent one. Power-cycle instead.

---

## 2. The fast path

**Did the driver die, and how often?**

    systemctl show -p NRestarts roverrobotics.service can.service
    journalctl -u roverrobotics.service -b --no-pager | tail -40
    journalctl -u can-watchdog -b --no-pager | grep -c restarting

On more than one second of total CAN silence the driver logs one FATAL and exits **with
status 0**, which reads like a graceful stop, and systemd restarts it five seconds
later. The fault looks like ROS restarting, not like a CAN error, so a climbing
`NRestarts` is the strongest single indicator that the bus went away. `can-watchdog`
logs nothing on a healthy robot, so its count is a fault count: `adapter NOT present on
USB` means the cable or connector, `UP but BUS-OFF` means an electrical fault.

**Then run the self-test.**

    sudo can-selftest

Stage 1 is loopback and needs no bus partner, so it isolates the adapter: **WEDGED** is
conclusive and only a physical replug clears it. Stage 2 listens passively and names
which of the four VESCs are broadcasting. Stage 3 sweeps the common bitrates if the bus
is silent. It stops the driver, restores through an exit trap so it cleans up even if
interrupted, and writes `/tmp/can-selftest-<timestamp>.log`.

**Send us that log.** One file, world-readable, no passwords or keys: identity and
kernel, the config the running driver actually loaded, the `gs_usb` module and its
package owner, USB enumeration and the driver bound to each CAN interface, the link
counters sampled twice with a diff, three seconds of bus traffic, service and restart
counts, CAN-relevant `dmesg`, and three journals. Plain text with `#####` markers, so it
also feeds an analysis tool. It contains hostnames and file paths.

Send the VESC Tool side with it: the fault log and CAN settings for each controller,
the firmware version of each, and photographs of the CAN wiring showing where the two
terminators sit. Tell us the wall-clock time the fault occurred and what the robot was
doing, because the journal and the CAN counters both reset on reboot, so timestamps are
what let us line things up.

Older installs stop after loopback and write no log. `grep -c STAGE
/usr/sbin/can-selftest` returning zero means the older version; sections 4 and 5 are the
manual equivalents, and re-running `setup_rover.sh` reinstalls the current script.

---

## 3. Five questions, before any testing

**a. OS or kernel updated since delivery?** The CAN module is not part of a stock L4T
install.

    uname -r
    modinfo -n gs_usb || echo "gs_usb MISSING"
    dpkg -S "$(modinfo -n gs_usb)" 2>&1 | tail -1
    ls -1 /lib/modules/
    grep -iE ' (upgrade|install) ' /var/log/apt/history.log | tail -20

No `modinfo` output is itself the fault: there will be no CAN interface at all. No
owning package means a kernel upgrade will remove the module. A running kernel that is
not the newest under `/lib/modules` means a kernel was installed and the module did not
follow.

**b. Driver repository pulled or rebuilt?** Our installer rewrites `device_port: can0`
to `rovercan`; a `git pull` reverts it.

    CLONE=~/rover_workspace/src/roverrobotics_ros2
    git -C $CLONE log -3 --date=short --format='%h %ad %s'
    git -C $CLONE status --porcelain
    git -C $CLONE reflog --date=short | head -10
    ps -eo args | grep '[r]overrobotics_driver/roverrobotics_driver'
    grep -n 'device_port' <the path after --params-file above>

Read it from the config the running driver loaded, not from a file on disk.
`device_port` must be `rovercan`; `can0` is the fault. A reflog `pull` dated after
delivery confirms how it happened.

**c. Clock stepped?** The CAN layer's one-second timeout uses wall clock, so a step back
hides a real outage and a step forward kills the driver instantly.

    timedatectl
    systemctl is-active systemd-timesyncd chrony ntp 2>/dev/null
    journalctl -b --no-pager | grep -iE 'time has been changed|timesyncd|synchronized to' | tail -20

`Time has been changed` within a second or two of a driver FATAL means the clock, not
CAN. Check this whenever a robot has joined a new network.

**d. Fails only while driving?** A USB cable fault shows as `-EPIPE` on *transmit* URBs,
and transmit only loads up while commanding motors, so an idle soak proves nothing.
Wheels off the ground, in one shell:

    while true; do date -Is; ip -s link show rovercan | sed -n '3p;5p'; sleep 5; done | tee /tmp/canwatch.txt

and `journalctl -fu roverrobotics.service` in another. Twenty minutes idle, then twenty
driving. Clean idle and failing under load points at the USB cable or the VESC current
limits, not the wiring.

**e. What recovers it?** In order, noting which one works.

    sudo systemctl restart roverrobotics.service
    sudo ip link set rovercan down && sudo ip link set rovercan up
    sudo systemctl restart can.service
    # then unplug and replug the adapter
    # last resort: full power cycle

Driver restart means software state, not the bus. `down/up` means a transient bus fault
or a stuck transmit queue. `can.service` means the adapter needed its USB-level reset. A
replug means a wedged adapter. A power cycle points at the adapter or the VESC side.

If other software on the robot commands the drivetrain, claims USB devices, or powers
hub ports down when idle, say whether it was running. All three have caused this, and on
robots with switchable hub ports a device missing from `lsusb` is not proof the hardware
is gone.

---

## 4. Manual checks, with what a healthy robot prints

**Adapter on USB**

    lsusb | grep -i 1d50:606f

    Bus 001 Device 005: ID 1d50:606f OpenMoko, Inc. Geschwister Schneider CAN adapter

A Geschwister Schneider / candleLight board and an InnoMaker USB2CAN both report
`1d50:606f`; only the product string differs, for example `USB2CAN V3.3`. Match on the
USB ID, never the brand name. Our udev rule keys off the ID alone, so either is
plug-and-play as `rovercan`.

**The right interface, bound to the right driver**

    for i in /sys/class/net/can* /sys/class/net/rovercan; do
      [ -e "$i" ] && echo "$(basename $i) -> $(basename $(readlink -f $i/device/driver))"
    done

    can1 -> mttcan
    can2 -> mttcan
    rovercan -> gs_usb

`rovercan` must be `gs_usb`. The `mttcan` entries are onboard controllers with nothing
wired to them; section 8 says why that matters.

**Link state, sampled twice.** Absolute counters are nearly useless here, for the
reasons in section 8. What matters is what moves.

    ip -details -statistics link show rovercan > /tmp/can1
    sleep 6
    ip -details -statistics link show rovercan > /tmp/can2
    diff /tmp/can1 /tmp/can2

A single reading should show `UP`, `ERROR-ACTIVE`, `bitrate 500000`, `sample-point
0.875`, and a `parentdev` naming the USB port, which is worth recording:

    11: rovercan: <NOARP,UP,LOWER_UP,ECHO> mtu 16 ... state UP ...
        can state ERROR-ACTIVE restart-ms 0
          bitrate 500000 sample-point 0.875
          re-started bus-errors arbit-lost error-warn error-pass bus-off
          0          0          0          0          0          0
        RX:  bytes packets errors dropped  missed   mcast
            374248   46781      0       0       0       0
        TX:  bytes packets errors dropped carrier collsns
            163968   40992      0       0       0       0

On a healthy robot the diff shows only the RX and TX byte and packet counts rising,
374248/46781 to 395672/49459 and 163968/40992 to 173424/43356. The `re-started
bus-errors ... bus-off` line does not appear in the diff at all. A difference on that
line, or a rising dropped count, is a live fault.

**Who is talking, and how fast**

    timeout 3 candump rovercan | awk '{print $2}' | sort | uniq -c | sort -rn

    297 00000101   297 00000102   297 00000103   297 00000104
    149 00000901   149 00000903   149 00001001   149 00001B01   ...
    148 00000902   148 00000904   148 00001B02   148 00001B04

`0x0101`-`0x0104` are the driver's commands, 297 in three seconds being about 99 Hz per
VESC. `0x0901`-`0x0904` are status 1 from the four controllers at about 50 Hz,
`0x1B01`-`0x1B04` are status 5, and `0x1001` is status 4 from VESC 1 only, which is
correct and not a fault. About 840 frames per second in total.

Any whole multiple of 99 Hz on the command IDs means more than one driver instance is
running. Each adds its own command stream, and enough of them saturate the bus and drop
status frames unevenly. Count them with
`ps -eo args | grep -c '[r]overrobotics_driver/roverrobotics_driver'`.

**Services**

    systemctl is-active roverrobotics.service can.service can-watchdog.timer
    systemctl show -p NRestarts roverrobotics.service can.service
    journalctl -b --no-pager | grep -c ENOBUFS

Three active, both restart counts zero, no ENOBUFS.

---

## 5. If the bus is silent: bitrate, or nothing talking?

A wrong bitrate and an absent bus look identical to `candump`. This sweep separates them
and stays passive: listen-only never transmits and never acknowledges, so it cannot
disturb the bus or any autonomy stack, and the adapters fitted to these robots support
the mode.

    sudo systemctl stop roverrobotics.service
    for B in 125000 250000 500000 800000 1000000; do
      sudo ip link set rovercan down
      sudo ip link set rovercan type can bitrate $B listen-only on
      sudo ip link set rovercan up
      echo -n "$B: "; timeout 2 candump -n 50 rovercan | wc -l
    done
    sudo systemctl restart can.service && sudo systemctl start roverrobotics.service

On a healthy robot with the computer deliberately set to 250000, this prints `500000: 50`
and zero at every other rate. Frames at one rate only is correct. Frames at a rate other
than the configured one mean the controllers and the computer disagree, and four VESCs
agreeing outweigh one adapter, so suspect the computer first: `BITRATE` in
`/usr/sbin/enablecan`. A bitrate cannot be validated with one node, and zero errors on a
silent bus proves nothing.

Make sure that last line runs. An interface left in listen-only gives you a robot that
hears the VESCs perfectly and never transmits again.

With the driver stopped the four VESCs still broadcast on their own, so you should see
`00000901` through `00000904`. All four means the adapter, wiring, termination and
bitrate are fine and the problem is above CAN. They sit on one daisy-chained trunk, so a
lead disturbed mid-chain takes out everything beyond it and can stop your own transmit
too: several missing at once usually means one connector, not several failed
controllers. To test one controller alone, use the one at the end of the chain.

Nothing at any rate means the adapter is fine and nothing else is participating:

- Robot powered, e-stop released. The e-stop is the most common version of this.
- CAN cable adapter-to-rover, seated at both ends.
- Termination: power off, measure CAN-H to CAN-L on the trunk. About 60 ohm means both
  terminators and a continuous trunk, about 120 ohm means one, open circuit means none
  or a broken conductor.
- Were the VESCs ever calibrated? An uncalibrated VESC never puts a frame on the bus, so
  a new robot, or one with a replacement controller, can leave a good bus looking dead.

---

## 6. Driver-side health

`/diagnostics` at 5 Hz, status name `roverrobotics_driver: drivetrain`, is what to watch
remotely. There is no `/robot_health` topic on any of our robots.

| Key | Healthy |
|---|---|
| `motion_blocked_by` | `none`. Other values: `soft_estop`, `stale_vesc`, `cmd_timeout` |
| `soft_estop` | `false` |
| `stale_vesc` | `0` |
| `vesc1_age_ms` .. `vesc4_age_ms` | 10 to 17 ms. 100000 means no frame ever received |
| `cmd_age_ms` | not usable, see section 8 |

`/odometry/wheels` should run at 15.0 Hz and `/robot_status` at about 60 Hz.

---

## 7. VESC side

VESC Tool over USB, one controller at a time; none of this is possible from the
computer.

**Read the fault log before any power cycle.** Subtract the DRV fault logged at about
21 V on every power-up.

Per controller: CAN ID 1 to 4, each used once; 500 kbit/s classic CAN, not FD; and
**status message 1 enabled**. That last one matters most, because the driver stamps a
controller's freshness only from status 1, so a VESC sending status 4 and 5 but not
status 1 holds the whole robot stopped while the driver still reports itself connected.

Our fleet standard is status 1 and 5 on all four, status 4 on VESC 1 only, and Hall
Interpolation ERPM 50. That value cannot be read over CAN; left at the factory 500 it
halves reported speed below 500 eRPM.

Also read Motor Current Max, Battery Current Max and Absolute Max. A direction reversal
draws 19 to 27.7 A per wheel, roughly 100 A at the pack momentarily. Limits below that
make a controller fault and drop off the bus under load, which presents as an
intermittent CAN disconnection that only happens while driving.

Set a Timeout Brake Current on each controller while you are there. Without it the VESCs
coast on their last command if the driver dies abruptly, instead of braking.

---

## 8. What not to trust

**A clean `ip link` output is not evidence of a healthy bus.** Sample twice and diff, as
in section 4, because:

- `rx_packets` climbs on a dead bus. A bus with nothing alive on it can report hundreds
  of thousands of frames alongside `errors 0`, every one an error frame. SocketCAN
  delivers error frames as ordinary frames, and `errors` counts driver-level errors, not
  CAN protocol errors.
- `error-warn`, `error-pass` and `bus-off` are cumulative and never reset. We have seen
  763,907 and 12,127 on a perfectly healthy machine.
- `berr-reporting` is off on this adapter, so `berr-counter` reads zero regardless.
- `restart-ms` is 0, so the `restarts` counter cannot rise even while the bus is dead.
- Dropped frames are normally a startup burst. On one robot the count sat frozen at
  4,850 while received frames climbed from 35,363 to 41,527 over twenty seconds. Only a
  rising count is a fault.

**`LOWER_UP` does not mean the VESCs are acknowledging.** It appears with nothing else
on the bus, and an adapter can read `UP`, `LOWER_UP` and `ERROR-ACTIVE` at the right
bitrate with its CAN core completely dead.

**An interface that looks perfect may be the wrong interface.** An onboard `mttcan`
controller with nothing wired to it comes up `UP` and `ERROR-ACTIVE`, passes every
`systemctl` and `ip link` check, and carries no data. Check the driver symlink, not the
interface name. A related tell: `can.service` configuring the link successfully as
CAN-FD means you are on an onboard controller, because `gs_usb` has no FD.

**The driver's "connected" state means "a frame arrived from somebody".** It is set for
every frame received, before parsing, with no ID filter. One surviving VESC, a foreign
node or a stray `cansend` keeps it looking connected while the wheels are dead.

**`cmd_age_ms` and `motion_blocked_by: cmd_timeout` are not usable.** An internal 50 ms
timer re-stamps the command timestamp unconditionally, so the value always reads 0 to 50
and that timeout never fires. Use the driver's own
`cmd_vel timeout (0.35s > 0.30s). HALT.` line instead.

**The useful driver messages are not on `/rosout`.** Write errors, stale-VESC lines and
the interface-not-found line go to stderr and reach the journal only because of how the
launch file is configured. Read `journalctl -u roverrobotics.service`.

**Noise that is not a fault.** Please do not chase these:

- One `VESC 1 feedback stale (NNNNN ms): holding all motors stopped` at startup,
  immediately followed by the first-data line. Before any frame arrives all four ages
  are equal and the lowest ID wins the tie, so it is not a statement about VESC 1.
- `cmd_vel timeout (0.3Xs > 0.30s). HALT.` once per stick release.
- `can.service` logging `no 1d50:606f adapter found on the USB bus to reset` when the
  adapter is unplugged for VESC Tool work.
- `RTNETLINK answers: Operation not supported` at `can.service` startup: the bring-up
  script tries CAN-FD first and steps down. `classic CAN (500000), no FD or
  berr-reporting` is the correct end state.

---

## 9. Known signatures

| What you see | What it means |
|---|---|
| `-EPIPE` on transmit URBs, then `USB disconnect`, then re-enumeration with a new device number | Failing USB cable. Load-dependent, about 23 minutes to first failure |
| `UP` and `ERROR-ACTIVE`, zero traffic, loopback fails | Wedged adapter. No software reset recovers this state, not even cutting power to the USB port; it needs a physical replug |
| `UP` and `ERROR-ACTIVE`, zero traffic, loopback passes | Rover unpowered, e-stop engaged, cable off, no termination, or VESCs never calibrated |
| No traffic ever, from new wiring | CAN-H and CAN-L swapped |
| Driver restart-looping on `Error in the socket bind ... rovercan` | Interface absent. Adapter unplugged, or `device_port` reverted to `can0` |
| Command IDs at a multiple of 99 Hz per VESC | More than one driver instance on the bus |
| Robot refuses to move, every ROS topic looks normal | One or more controllers quiet. Read `stale_vesc` and the four `vesc_age_ms` keys |
| Speed under-reads below walking pace | Hall Interpolation ERPM left at the factory 500 instead of 50 |
| Interface `UP`, `ERROR-ACTIVE`, 0 errors, no data, forever | Driver bound to an onboard `mttcan` controller instead of the USB adapter |

