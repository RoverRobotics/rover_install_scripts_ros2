# CAN Diagnostics

Rover Robotics. For rovers that drive four VESC motor controllers over a USB-CAN
adapter on SocketCAN, running the `roverrobotics` ROS 2 driver. Covers MITI, Mini,
MAX and Mega.

This is the procedure we use on our own fleet, in the order we use it. The expected
outputs below were measured on an AGX Orin MITI on 17 November 2026.

Read section 1 first. Two of the obvious things to try destroy the evidence needed to
find the cause.

---

## 1. Before you touch the robot

**Get the wheels off the ground, and stop the driver before touching any CAN
connector.** A VESC holds the last duty it was given until its own timeout, and while
the bus is down the driver keeps queueing writes it cannot send. Those queue up and are
delivered the moment the bus comes back, so a robot can move when a cable is reseated.

    sudo systemctl stop roverrobotics.service

or at minimum flush the queue with `sudo ip link set rovercan down; sudo ip link set rovercan up`.

**Do not power-cycle yet.** The VESC fault log is volatile and a power cycle erases it.
It is the most useful evidence on the machine. Read it first, section 8. Every power-up
writes one DRV fault at about 21 V; ignore that one.

**Do not warm-reboot as a first step.** On this hardware a warm reboot can wedge the
USB-CAN adapter in a state no software recovers, turning an intermittent fault into a
permanent one. If you must restart, power-cycle rather than reboot.

---

## 2. Five questions, before any testing

The answers eliminate whole layers.

### a. Has the OS or kernel been updated since delivery?

The CAN kernel module is not part of a stock L4T install.

    uname -r
    modinfo -n gs_usb || echo "gs_usb MISSING"
    dpkg -S "$(modinfo -n gs_usb)" 2>&1 | tail -1
    ls -1 /lib/modules/
    grep -iE ' (upgrade|install) ' /var/log/apt/history.log | tail -20

If `modinfo -n gs_usb` prints nothing, that is the fault and there will be no CAN
interface at all. If `dpkg -S` reports no package owns the file, the module was added
outside the package manager, which means a kernel upgrade will remove it. More than one
directory under `/lib/modules` with the running kernel not the newest one is the sign
that a kernel was installed and the module did not follow it.

### b. Has the driver repository been pulled or rebuilt?

Our installer rewrites `device_port: can0` to `rovercan`. A `git pull` in the driver
clone reverts that, and the driver then cannot find the interface.

    CLONE=~/rover_workspace/src/roverrobotics_ros2
    git -C $CLONE log -3 --date=short --format='%h %ad %s'
    git -C $CLONE status --porcelain
    git -C $CLONE reflog --date=short | head -10

Then check the value that actually matters, read from the config the running driver
loaded rather than any file on disk:

    ps -eo args | grep '[r]overrobotics_driver/roverrobotics_driver'
    grep -n 'device_port' <the path after --params-file above>

`device_port` must read `rovercan`. If it reads `can0`, that is the fault. A reflog
entry mentioning `pull` dated after delivery confirms how it happened.

### c. Has the clock stepped?

The CAN layer's one-second connection timeout uses wall clock, not a monotonic clock. A
step backwards hides a real outage; a step forwards declares one instantly and kills the
driver. This is worth checking whenever a robot has joined a new network.

    timedatectl
    systemctl is-active systemd-timesyncd chrony ntp 2>/dev/null
    journalctl -b --no-pager | grep -iE 'time has been changed|timesyncd|synchronized to|rtc' | tail -20

A `Time has been changed` line within a second or two of a driver FATAL means the clock
caused it, not CAN.

### d. Does it fail only while driving?

A USB cable fault shows as `-EPIPE` on *transmit* URBs, and transmit only loads up while
commanding motors, so an idle soak can pass for half an hour and prove nothing. Test it
deliberately. With the wheels off the ground, in one shell:

    while true; do date -Is; ip -s link show rovercan | sed -n '3p;5p'; sleep 5; done | tee /tmp/canwatch.txt

and in another:

    journalctl -fu roverrobotics.service

Leave that idle for twenty minutes, then drive it for twenty. If it stays clean idle and
fails within minutes of driving, the fault is load-dependent, which points at the USB
cable or the VESC current limits rather than the bus wiring.

### e. What recovers it?

Try these in order when it next fails, and note which one works.

    sudo systemctl restart roverrobotics.service
    sudo ip link set rovercan down && sudo ip link set rovercan up
    sudo systemctl restart can.service
    # then unplug and replug the USB-CAN adapter
    # last resort: full power cycle

A driver restart alone means software state, not the bus. `down/up` means a transient
bus fault or a stuck transmit queue. A `can.service` restart means the adapter needed
its USB-level reset. Needing a physical replug means a wedged adapter. Needing a full
power cycle points at the adapter or the VESC side.

If the robot runs software from another vendor that commands the drivetrain, claims USB
devices, or powers hub ports down when idle, say whether it was running at the time. We
have seen all three interfere, and on robots with switchable hub ports a device missing
from `lsusb` is not by itself proof the hardware is gone.

---

## 3. The fast path

**a. Did the ROS driver die, and how often?**

    systemctl show -p NRestarts roverrobotics.service can.service
    journalctl -u roverrobotics.service -b --no-pager | tail -40
    journalctl -u can-watchdog -b --no-pager | grep restarting | wc -l

This is first for a reason. On more than one second of total CAN silence the driver
logs one FATAL and shuts down **with exit status 0**, which in the journal reads like a
graceful stop, and systemd restarts it five seconds later. The fault presents as ROS
restarting, not as a CAN error. A climbing `NRestarts` is the strongest single
indicator that the bus went away.

`can-watchdog` logs one line per intervention and nothing on a healthy robot, so that
count is a fault count. `adapter NOT present on USB` points at the cable or connector.
`UP but BUS-OFF` points at an electrical fault.

**b. Is the adapter alive?**

    sudo can-selftest

Loopback needs no bus partner, so it isolates the adapter from everything else. It
stops the driver, runs, and restores through an exit trap, so it cleans up even if
interrupted.

A **WEDGED** result is conclusive: the adapter, nothing else, and only a physical
unplug and replug clears it. A **HEALTHY** result clears only the adapter. It says
nothing about whether the VESCs are connected, powered or on the right bitrate, because
loopback deliberately takes the bus out of the picture. Use (c) for that.

**c. Is anything actually on the bus?**

    sudo systemctl stop roverrobotics.service
    sudo ip link set rovercan down
    sudo ip link set rovercan type can bitrate 500000 listen-only on
    sudo ip link set rovercan up
    timeout 3 candump rovercan | awk '{print $2}' | sort | uniq -c | sort -rn
    sudo systemctl restart can.service && sudo systemctl start roverrobotics.service

Listen-only never transmits and never acknowledges, so it cannot disturb the bus or any
autonomy stack. We confirmed on 17 November that this mode works on the adapter fitted
to these robots.

With the driver stopped the four VESCs still broadcast on their own, so you should see
`00000901` through `00000904`. All four present means the adapter, wiring, termination
and bitrate are all fine and the problem is above CAN. Some missing means those
controllers. Nothing at all, go to section 6.

Make sure that last line runs. An interface left in listen-only gives you a robot that
hears the VESCs perfectly and never transmits again.

---

## 4. The self-test log

`can-selftest` writes everything it sees to `/tmp/can-selftest-<timestamp>.log` and
prints the path when it finishes. The file is world-readable so it can be copied off
without root, and it carries no passwords or keys.

Send us that one file. It is a complete bundle: robot identity, kernel, which config
the running driver actually loaded, the `gs_usb` module and whether a package owns it,
USB enumeration, which driver each CAN interface is bound to, the link counters sampled
twice six seconds apart with a diff, three seconds of bus traffic with the driver
running, service states and restart counts, the CAN-relevant `dmesg` lines, and the
driver, `can.service` and `can-watchdog` journals for the current boot.

It is plain text with `#####` section markers, so it can also be pasted straight into
an analysis tool if that is how you prefer to work. Note that it contains hostnames and
file paths.

One caveat on which version you have. Older installs stop after three checks: adapter
on USB, interface exists, loopback. Newer ones add the bus-presence and bitrate stages
and the log. Check with `grep -c STAGE /usr/sbin/can-selftest` — zero means the older
version, and sections 3c and 6 below are the manual equivalents. Re-running
`setup_rover.sh` from the installer repository reinstalls the current script.

---

## 5. Manual checks, with what a healthy robot prints

Run these in order. Real output from a healthy AGX Orin MITI follows each one.

**Adapter present on USB**

    lsusb | grep -i 1d50:606f

    Bus 001 Device 005: ID 1d50:606f OpenMoko, Inc. Geschwister Schneider CAN adapter

Either a Geschwister Schneider / candleLight-family board or an InnoMaker USB2CAN can
be used, and both report the same `1d50:606f` ID. Only the product string differs, for
example `USB2CAN V3.3` on the InnoMaker. Match on the USB ID, never on the brand name.
Our bring-up and udev rule key off `1d50:606f` alone, so either adapter is
plug-and-play and gets named `rovercan`.

**The right interface, bound to the right driver**

    readlink -f /sys/class/net/rovercan/device/driver | xargs basename
    for i in /sys/class/net/can* /sys/class/net/rovercan; do
      [ -e "$i" ] && echo "$(basename $i) -> $(basename $(readlink -f $i/device/driver))"
    done

    gs_usb
    can1 -> mttcan
    can2 -> mttcan
    rovercan -> gs_usb

`rovercan` must be `gs_usb`. The `mttcan` entries are the board's onboard CAN
controllers with nothing wired to them. See section 9 for why that matters.

**Link state and counters**

    ip -details -statistics link show rovercan

    11: rovercan: <NOARP,UP,LOWER_UP,ECHO> mtu 16 qdisc pfifo_fast state UP mode DEFAULT group default qlen 10
        link/can  promiscuity 0 minmtu 0 maxmtu 0
        can state ERROR-ACTIVE restart-ms 0
          bitrate 500000 sample-point 0.875
          tq 125 prop-seg 6 phase-seg1 7 phase-seg2 2 sjw 2
          gs_usb: tseg1 1..16 tseg2 1..8 sjw 1..4 brp 1..1024 brp-inc 1
          clock 48000000
          re-started bus-errors arbit-lost error-warn error-pass bus-off
          0          0          0          0          0          0         numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535 parentbus usb parentdev 1-4.3:1.0
        RX:  bytes packets errors dropped  missed   mcast
            374248   46781      0       0       0       0
        TX:  bytes packets errors dropped carrier collsns
            163968   40992      0       0       0       0

`UP`, `ERROR-ACTIVE`, `bitrate 500000`, `sample-point 0.875`. `parentdev` tells you
which USB port the adapter is on, which is worth recording.

**Sample the counters twice.** Absolute values are nearly useless here, for the reasons
in section 9. What matters is what moves.

    ip -details -statistics link show rovercan > /tmp/can1
    sleep 6
    ip -details -statistics link show rovercan > /tmp/can2
    diff /tmp/can1 /tmp/can2

    11c11
    <         374248   46781      0       0       0       0
    ---
    >         395672   49459      0       0       0       0
    13c13
    <         163968   40992      0       0       0       0
    ---
    >         173424   43356      0       0       0       0

Only the RX and TX byte and packet counts changed. The error, bus-off and drop line did
not appear in the diff at all. That is what healthy looks like. A difference on the
`re-started bus-errors ... bus-off` line, or a rising dropped count, is a live fault.

**Who is talking, and how fast**

    timeout 3 candump rovercan | awk '{print $2}' | sort | uniq -c | sort -rn

    297 00000104
    297 00000103
    297 00000102
    297 00000101
    149 00001B03
    149 00001B01
    149 00001001
    149 00000903
    149 00000901
    148 00001B04
    148 00001B02
    148 00000904
    148 00000902

Reading that: `0x0101`-`0x0104` are the driver's own commands, 297 in three seconds is
about 99 Hz per VESC. `0x0901`-`0x0904` are status 1 from each of the four controllers
at about 50 Hz. `0x1B01`-`0x1B04` are status 5. `0x1001` is status 4 and comes from
VESC 1 only, which is correct, not a fault. Roughly 840 frames per second in total.

Any whole multiple of 99 Hz on the command IDs means more than one driver instance is
running. We once had thirteen, which saturated the bus and dropped status frames
unevenly. Count them with
`ps -eo args | grep -c '[r]overrobotics_driver/roverrobotics_driver'`.

**Services**

    systemctl is-active roverrobotics.service can.service can-watchdog.timer
    systemctl show -p NRestarts roverrobotics.service can.service
    journalctl -u can-watchdog -b --no-pager | grep -c restarting
    journalctl -b --no-pager | grep -c ENOBUFS

    active
    active
    active
    NRestarts=0
    NRestarts=0
    0
    0

Three active, both restart counts zero, no watchdog interventions, no ENOBUFS.

---

## 6. If the bus is silent: bitrate, or nothing talking?

A wrong bitrate and an absent bus look identical to `candump`. This sweep separates
them and stays passive throughout.

    sudo systemctl stop roverrobotics.service
    for B in 125000 250000 500000 800000 1000000; do
      sudo ip link set rovercan down
      sudo ip link set rovercan type can bitrate $B listen-only on
      sudo ip link set rovercan up
      echo -n "$B: "; timeout 2 candump -n 50 rovercan | wc -l
    done
    sudo systemctl restart can.service && sudo systemctl start roverrobotics.service

On a healthy robot deliberately misconfigured to 250000, this printed:

    125000: 0
    250000: 0
    500000: 50
    800000: 0
    1000000: 0

Frames at 500000 and nothing elsewhere is correct. Frames at some other rate mean the
controllers and the computer disagree. Four VESCs agreeing outweigh one adapter, so
suspect the computer first: `BITRATE` in `/usr/sbin/enablecan`.

A bitrate cannot be validated with one node. Zero errors on a silent bus proves
nothing.

Nothing at any rate means the adapter is fine and nothing else is participating:

1. Robot powered and e-stop released. The e-stop is the most common version of this.
2. CAN cable between adapter and rover, seated at both ends.
3. Termination. Power the robot off and measure CAN-H to CAN-L anywhere on the trunk.
   About 60 ohm means both terminators present and the trunk continuous. About 120 ohm
   means one. Open circuit means none, or a broken conductor.
4. Were the VESCs ever calibrated? An uncalibrated VESC does not participate on the bus
   at all, so a freshly built robot, or one with a replacement controller fitted, can
   leave a perfectly good bus looking completely dead.

Before interpreting a partial result, remember that the controllers sit on one
daisy-chained trunk. A lead disturbed mid-chain takes out everything beyond it and can
stop your own transmit as well, so several controllers missing at once usually means a
single connector rather than several failed controllers. To test one controller in
isolation, use the one at the end of the chain.

---

## 7. Driver-side health

`/diagnostics` at 5 Hz, status name `roverrobotics_driver: drivetrain`, is what to watch
remotely. There is no `/robot_health` topic on any of our robots.

| Key | Healthy |
|---|---|
| `motion_blocked_by` | `none`. Other values: `soft_estop`, `stale_vesc`, `cmd_timeout` |
| `soft_estop` | `false` |
| `stale_vesc` | `0` |
| `vesc1_age_ms` .. `vesc4_age_ms` | 10 to 17 ms. 100000 means no frame ever received |
| `cmd_age_ms` | not usable, see section 9 |

`/odometry/wheels` should run at 15.0 Hz and `/robot_status` at about 60 Hz.

---

## 8. VESC side

These need VESC Tool over USB, one controller at a time, and cannot be done from the
computer.

**Read the fault log before any power cycle.** Subtract the one DRV fault logged at
about 21 V on every power-up.

Then per controller: CAN ID 1 to 4, each used exactly once; CAN bitrate 500 kbit/s
classic rather than FD; and **status message 1 enabled**. That last one matters more
than it looks. The driver stamps a controller's freshness only from status 1, so a VESC
sending status 4 and 5 but not status 1 will hold the whole robot stopped while the
driver still reports itself connected.

Our fleet standard is status 1 and 5 on all four, status 4 on VESC 1 only, and Hall
Interpolation ERPM set to 50. That last value cannot be read over CAN; left at the
factory 500 it halves reported speed below 500 eRPM.

Also read Motor Current Max, Battery Current Max and Absolute Max. We measured 19 to
27.7 A per wheel during a direction reversal, roughly 100 A at the pack momentarily. If
your limits sit below that, a controller faults and drops off the bus under load, which
presents as an intermittent CAN disconnection that only happens while driving.

While you are in there, set a Timeout Brake Current on each controller. Without it the
VESCs coast on their last command if the driver dies abruptly, instead of braking.

---

## 9. What not to trust

**A clean `ip link` output is not evidence of a healthy bus.** Four reasons on this
hardware:

- `rx_packets` climbs on a dead bus. A bus with nothing alive on it can report hundreds
  of thousands of frames received alongside `errors 0`, and every one of those frames
  can be an error frame. SocketCAN delivers error frames as ordinary frames, and the
  `errors` column counts driver-level errors, not CAN protocol errors.
- `error-warn`, `error-pass` and `bus-off` are cumulative and never reset. We have seen
  763,907 and 12,127 on a perfectly healthy machine.
- `berr-reporting` is off on this adapter, so `berr-counter` reads zero regardless.
- `restart-ms` is 0, so the `restarts` counter cannot rise even while the bus is dead.

Sample twice and diff, as in section 5. Dropped received frames are normally a startup
burst: on one robot the count sat frozen at 4,850 while received frames climbed from
35,363 to 41,527 over twenty seconds. Only a rising count is a fault.

**`LOWER_UP` does not mean the VESCs are acknowledging.** An older version of our setup
guide says it does. That is wrong and we are correcting it. A CAN interface shows
`LOWER_UP` with nothing else on the bus, and we have a measured case of an adapter
reading `UP`, `LOWER_UP` and `ERROR-ACTIVE` at the right bitrate with its CAN core
completely dead.

**An interface that looks perfect may be the wrong interface.** These boards have
onboard CAN controllers, `can1` and `can2` in the output above. One with nothing wired
to it comes up `UP` and `ERROR-ACTIVE`, passes every `systemctl` and `ip link` check,
and carries no data. Check the driver symlink, not the interface name. A related tell:
if the journal shows `can.service` configuring the link successfully as CAN-FD, you are
on an onboard controller, because `gs_usb` does not support FD.

**The driver's "connected" state means "a frame arrived from somebody".** It is set for
every frame received, before parsing, with no ID filter. One surviving VESC, a foreign
node or a stray `cansend` keeps it looking connected while the wheels are dead.

**`cmd_age_ms` and `motion_blocked_by: cmd_timeout` are not usable.** An internal 50 ms
timer re-stamps the command timestamp unconditionally, so that value always reads 0 to
50 and that timeout never fires. Use the driver's own
`cmd_vel timeout (0.35s > 0.30s). HALT.` line instead.

**The useful driver messages are not on `/rosout`.** Write errors, stale-VESC lines and
the interface-not-found line go to stderr and reach the journal only because of how the
launch file is configured. Read `journalctl -u roverrobotics.service`.

**Noise that is not a fault.** Please do not chase these:

- One `VESC 1 feedback stale (NNNNN ms): holding all motors stopped` at startup,
  immediately followed by the first-data line. It names VESC 1 because before any frame
  arrives all four ages are equal and the lowest ID wins the tie. It is not a statement
  about VESC 1.
- `cmd_vel timeout (0.3Xs > 0.30s). HALT.` once per stick release.
- `can.service` logging `no 1d50:606f adapter found on the USB bus to reset` when the
  adapter has been unplugged for VESC Tool work.
- `RTNETLINK answers: Operation not supported` during `can.service` startup. The
  bring-up script tries CAN-FD first and steps down. `classic CAN (500000), no FD or
  berr-reporting` is the correct end state.

---

## 10. Signatures we have seen before

| What you see | What it was |
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

---

## 11. What to send us

If the fast path does not resolve it, send the `can-selftest` log from section 4. That
is the whole bundle in one file.

If you are on the older script, this is the equivalent, captured while the fault is
present if possible:

    uname -r; modinfo -n gs_usb; dpkg -S $(modinfo -n gs_usb) 2>&1 | tail -1
    lsusb; lsusb -t
    sudo dmesg -T | grep -iE 'gs_usb|mttcan|rovercan|usb disconnect|EPIPE' | tail -60
    ip -details -statistics link show rovercan          # twice, 6 seconds apart
    readlink -f /sys/class/net/rovercan/device/driver
    timeout 5 candump -ta rovercan > /tmp/candump.txt   # with the driver running
    ps -eo args | grep '[r]overrobotics_driver/roverrobotics_driver'
    systemctl show -p NRestarts roverrobotics.service can.service
    systemctl status can.service can-watchdog.timer roverrobotics.service --no-pager
    journalctl -u roverrobotics.service -u can.service -u can-watchdog -b --no-pager
    journalctl --list-boots

Plus, from VESC Tool, the fault log and CAN settings for each controller, the firmware
version of each, and photographs of the CAN wiring showing where the two terminators
sit.

Tell us the wall-clock time the fault occurred and what the robot was doing. The
journal and the CAN counters both reset on reboot and do not carry across boots, so
timestamps are what let us line things up.
