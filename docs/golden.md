# Golden Image Runbook v2 — Rover Robotics AGX Orin Fleet

Verified against the actual hardware on 2026-07-29. Every value in the table
below was read off the real machines, not assumed.

Supersedes `golden-image-runbook.md`. The differences that matter are marked
**[NEW]** — v1 would have produced 100 robots with no SSH.

---

## Verified hardware facts

| Item | Value | How verified |
|---|---|---|
| ROVER-A address | `rover@10.1.10.53` | ssh |
| Board | NVIDIA Jetson AGX Orin Developer Kit | `/proc/device-tree/model` |
| L4T | R36 REVISION 4.7 (JetPack 6.2) | `/etc/nv_tegra_release` |
| OS | Ubuntu 22.04.5 LTS aarch64 | `lsb_release -d` |
| SSD | Patriot M.2 P320 512GB, s/n `P320WCB26020900029` | `efibootmgr -v` |
| Disk | 476.9 G, GPT, **15 partitions**, root on `nvme0n1p1` | `lsblk` |
| Root PARTUUID | `ddede667-4aba-4c6e-b591-91ca6f9cc05a` | `blkid` |
| Sector size | 512 logical / 512 physical | `/sys/block/...` |
| Rootfs used | 24 G of 467 G | `df -h /` |
| **eMMC** | **59.2 G, populated, own 15-part layout, bootable** | `lsblk /dev/mmcblk0` |
| eMMC rootfs PARTUUID | `1f488847-6d5e-46f1-bc4d-423c69888b06` | `blkid` |
| Boot order | `0001` NVMe → `0002` **eMMC** → … | `efibootmgr` |
| ROS | Humble, workspace `~/rover_workspace` | `/opt/ros/humble` |

### The host (this laptop)

| Item | Value |
|---|---|
| OS | Ubuntu 24.04.4 LTS x86_64 |
| Free space | 455 G on `/` |
| **Own disk 1** | **`/dev/nvme0n1` — Linux root. NEVER a target.** |
| **Own disk 2** | **`/dev/nvme1n1` — Windows. NEVER a target.** |
| Tools present | zstd, zerofree, e2fsck, sgdisk, partprobe, udisksctl |

---

## The one safety rule

> **On this laptop, every internal disk is named `nvme…`.
> The Jetson SSD in the USB reader is named `sdX`.
> If a `dd` command you are about to run contains the string `nvme`, STOP.**

`dd` has no confirmation and no undo.

---

## The three machines

| Label | What it is |
|---|---|
| **ROVER-A** | `10.1.10.53`. The golden source. |
| **HOST** | This laptop. Runs the reader, holds the image, flashes new units. |
| **ROBOT-N** | Each new robot being built. |

HOST is x86_64 and is not ROVER-A, so there is no PARTUUID collision risk.

---

## Phase 0 — HOST preparation (once)

**0.1** Install tools (all present already except `pv`, which is optional):

```bash
sudo apt update && sudo apt install -y zstd zerofree gdisk pv
```

**0.2** Create the image directory:

```bash
mkdir -p ~/golden && cd ~/golden
```

**0.3** Confirm you can flash JetPack 6.2 / L4T 36.4.7.

> **Caveat:** NVIDIA SDK Manager officially targets Ubuntu 20.04/22.04 hosts.
> This laptop is 24.04. If SDK Manager misbehaves, use NVIDIA's SDK Manager
> **Docker image** (Docker 29.6.2 is installed and running here), which
> sidesteps the host OS version entirely. For 100 units, prefer the scriptable
> BSP CLI (`l4t_initrd_flash.sh`) over the GUI — confirm the exact R36.4.7
> invocation against the BSP flash README before relying on it.

---

## Phase 1 — Prepare the golden system (on ROVER-A)

Run over SSH from HOST. Do these in order and **do not reboot** — the phase
ends in `poweroff`.

```bash
ssh rover@10.1.10.53      # password: rover
```

### 1.1 — Kill history logging for this session

Otherwise your shell rewrites `~/.bash_history` on logout, after you erased it.

```bash
export HISTFILE=/dev/null
```

### 1.2 — Confirm everything works

Whatever is broken now ships to all 100 robots.

```bash
systemctl is-active rover-realsense.service      # expect: active
source /opt/ros/humble/setup.bash
source ~/rover_workspace/install/setup.bash
ros2 topic list
```

> **[NEW]** `ros2` is sourced from `.bashrc`, so it exists only in interactive
> shells. `ssh rover@host 'ros2 topic list'` returns *command not found*. Always
> source explicitly in scripts, or use `ssh rover@host 'bash -ic "..."'`.

### 1.3 — librealsense build tree

**Already done on ROVER-A** (2026-07-29 13:29). The manifest is preserved at
`/usr/local/share/librealsense2-install_manifest.txt` and
`~/librealsense_build` is gone. **Do not re-run** — the `cp` will fail on the
missing source. Verify only:

```bash
ls -l /usr/local/share/librealsense2-install_manifest.txt
ls /usr/local/lib/librealsense2.so.2.58
```

### 1.4 — **[NEW]** Install the SSH host-key regeneration unit

**This is the step whose absence breaks the entire fleet.** Verified on this
Jetson: `ssh.service` runs `ExecStartPre=/usr/sbin/sshd -t`, which exits 1 with
no host keys; there is no `sshd-keygen@.service`; `cloud-init` is not
installed; and `/etc/nv/nvfirstboot` is gone so `oem-config` will not re-run.
Delete the host keys without this unit and **`ssh.service` fails to start on
every clone.**

```bash
sudo tee /etc/systemd/system/regen-ssh-hostkeys.service >/dev/null <<'EOF'
[Unit]
Description=Regenerate OpenSSH host keys if absent (golden image first boot)
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service ssh.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable regen-ssh-hostkeys.service
```

Confirm the enable symlink exists — it is what ships in the image:

```bash
ls -l /etc/systemd/system/multi-user.target.wants/regen-ssh-hostkeys.service
```

The `ConditionPathExistsGlob` makes it self-disabling: it fires once on each
clone's first boot and never again.

### 1.5 — Reclaim space before imaging

`/var/cache/apt/archives` is **1.8 G** on ROVER-A right now. Every gigabyte
here is a gigabyte in the image and in every write.

```bash
sudo apt clean
sudo journalctl --vacuum-time=1s
rm -rf ~/.cache/*
```

### 1.6 — Sysprep

Strips this unit's identity. Does **not** touch hostname, username, password,
or software — robots stay identical in every way you care about.

```bash
# machine identity
sudo truncate -s 0 /etc/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id     # [NEW] see note

# ssh host keys (safe now that 1.4 is in place)
sudo rm -f /etc/ssh/ssh_host_*

# [NEW] entropy seed — otherwise all 100 robots boot with an identical seed
sudo rm -f /var/lib/systemd/random-seed

# network leases
sudo rm -rf /var/lib/dhcp/*

# [NEW] comprehensive log wipe — `rm /var/log/*.log` misses most of it.
# Verified present on ROVER-A: syslog, btmp, wtmp, lastlog, dmesg,
# dmesg.0, dmesg.*.gz, Xorg.0.log.old — none match *.log
sudo find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
sudo truncate -s 0 /var/log/syslog /var/log/auth.log /var/log/kern.log 2>/dev/null
sudo truncate -s 0 /var/log/btmp /var/log/wtmp /var/log/lastlog
sudo find /var/log -type f -name '*.log' -exec truncate -s 0 {} \;

# shell history
rm -f ~/.bash_history
sudo rm -f /root/.bash_history
```

> **[NEW] On `/var/lib/dbus/machine-id`:** on this Jetson it is a **real file**,
> not a symlink (it differs from desktop Ubuntu here). v1's `rm -f` left it
> permanently absent. Replacing it with a symlink to `/etc/machine-id` makes it
> regenerate itself on every clone.

> `/etc/machine-id` is **truncated, not deleted.** An empty file is systemd's
> first-boot signal; a missing file breaks regeneration.

### 1.7 — Verify sysprep took

```bash
[ ! -s /etc/machine-id ] && echo "OK machine-id empty" || echo "FAIL machine-id"
ls /etc/ssh/ssh_host_* 2>/dev/null && echo "FAIL keys present" || echo "OK no host keys"
ls -l /etc/systemd/system/multi-user.target.wants/regen-ssh-hostkeys.service \
  >/dev/null 2>&1 && echo "OK keygen unit enabled" || echo "FAIL keygen unit"
```

**All three must say OK.** If the keygen unit says FAIL, go back to 1.4 — do
not proceed.

### 1.8 — Power off immediately

Booting again regenerates the identity you just cleared.

```bash
sudo poweroff
```

### 1.9 — Remove the NVMe SSD from ROVER-A

Label it **GOLDEN — ROVER-A — do not wipe**.

---

## Phase 2 — Capture the image (on HOST)

### 2.1 — Before/after device identification

```bash
lsblk -e7 -o NAME,SIZE,TYPE,TRAN,MODEL          # BEFORE plugging in
# ...insert SSD into USB reader...
lsblk -e7 -o NAME,SIZE,TYPE,TRAN,MODEL          # AFTER
```

The new ~476.9 G device with 15 partitions and `TRAN=usb` is the Jetson SSD.
It will be `/dev/sda`, `/dev/sdb`, … Set it once:

```bash
export SSD=/dev/sdX          # <-- substitute the real name
```

### 2.2 — Positively confirm by PARTUUID

```bash
lsblk -o NAME,SIZE,PARTUUID ${SSD} | head -3
sudo blkid -s PARTUUID -o value ${SSD}1
```

**Must print `ddede667-4aba-4c6e-b591-91ca6f9cc05a`. If it does not, you have
the wrong device — stop.**

Also confirm it is not internal:

```bash
lsblk -no TRAN ${SSD}      # must be: usb
```

### 2.3 — Unmount anything auto-mounted

```bash
sudo umount ${SSD}?* 2>/dev/null
lsblk ${SSD} -o NAME,MOUNTPOINT
```

MOUNTPOINT must be empty everywhere. `zerofree` corrupts a mounted filesystem.

### 2.4 — Filesystem check

`zerofree` refuses an unclean filesystem.

```bash
sudo e2fsck -f ${SSD}1
```

> **Note:** this and the next step **modify ROVER-A's only disk**, before any
> image exists. There is no backup at this moment. If you want a safety net,
> capture an unshrunk image first (~477 G raw, compresses poorly) — otherwise
> accept the risk consciously.

### 2.5 — Zero the free space

Overwrites only *unused* blocks so they compress away. Your data is untouched.
~450 G to zero, roughly 15–25 minutes.

```bash
sudo zerofree -v ${SSD}1
```

### 2.6 — Capture the whole disk

Note `if=${SSD}`, **not** `${SSD}1` — you need the GPT and all 15 partitions
including bootloader slots and the ESP.

```bash
cd ~/golden
sudo dd if=${SSD} bs=64M status=progress | zstd -T0 -9 > golden-r36.4.7.img.zst
```

Expect 20–40 minutes and roughly a 10 G result (24 G of real data).

### 2.7 — Record checksums **and the raw size**

The raw values are what let you verify a written SSD later. v1 checksummed only
the compressed file, which proves nothing about any write.

```bash
cd ~/golden
sha256sum golden-r36.4.7.img.zst | tee golden-r36.4.7.img.zst.sha256
zstdcat golden-r36.4.7.img.zst | tee >(sha256sum | cut -d' ' -f1 > golden.raw.sha256) | wc -c > golden.raw.size

cat golden.raw.size golden.raw.sha256
```

### 2.8 — Back up to a second location

```bash
cp golden-r36.4.7.img.zst* golden.raw.* /path/to/backup/
```

For the next two months this file is your entire product.

---

## Phase 3 — Return ROVER-A to service

**3.1** Reinstall the SSD in ROVER-A and boot. It becomes robot #1. First boot
is slower — that is the keygen unit running.

**3.2** Verify — **this is also your first proof that Phase 1 was correct:**

```bash
ssh rover@10.1.10.53 'systemctl is-active ssh; ls /etc/ssh/ssh_host_*'
ssh rover@10.1.10.53 'cat /etc/machine-id'
ssh rover@10.1.10.53 'bash -ic "ros2 topic list"' 2>/dev/null | grep -i camera
```

You will get a host-key-changed warning — expected, the keys are new. Clear it:

```bash
ssh-keygen -R 10.1.10.53
```

**If SSH does not come back, the keygen unit did not work. Fix it before
building any robots.**

---

## Phase 4 — Build each robot

### 4.1 (ROBOT-N) — Flash JetPack 6.2 first. Mandatory.

A factory AGX Orin ships with older L4T and will not boot the golden image —
black screen or a drop to UEFI, easily misread as a bad image.

Install the blank SSD in ROBOT-N, then flash from HOST:

- Target: **Jetson AGX Orin Developer Kit**
- Version: **JetPack 6.2 (L4T 36.4.7)**
- Storage target: **NVMe**

This delivers the three things the image cannot carry:

1. QSPI firmware at 36.4.7 — the actual requirement.
2. A UEFI boot entry for that SSD, ordered ahead of eMMC.
3. Consistent eMMC state.

> **[NEW] Why this cannot be skipped or shortcut:** UEFI boot variables live in
> **QSPI on the module, not on the SSD.** A block clone of the SSD carries no
> boot configuration whatsoever.

### 4.1a — **[NEW] The SSD-serial trap. Read this.**

The NVMe boot entry is bound to the drive's model **and serial number**:

```
Boot0001* UEFI Patriot M.2 P320 512GB P320WCB26020900029
BootOrder: 0001,0002,...
Boot0002* UEFI eMMC Device        <-- full bootable factory OS, 57.8 G
```

The eMMC on these devkits holds a **complete, bootable 15-partition OS**. So:

> **The SSD that gets flashed must be the same physical SSD that receives the
> golden image and goes back into that same robot.**

Shuffle drives between units — trivially easy with a bin of 100 identical
Patriots — and the serial no longer matches, `Boot0001` fails, and UEFI
**silently falls through to the eMMC and boots the factory OS.** The robot
powers on and shows a desktop; it just isn't your robot. Nobody diagnoses that
as a boot-order problem.

**Label every SSD with its robot number the moment it is flashed.**

### 4.2 (HOST) — Write the golden image

Remove the SSD from ROBOT-N, insert into the reader, identify it as in 2.1.

> **STOP.** Re-run `lsblk`. If the device name contains `nvme`, it is this
> laptop. Writing to it is unrecoverable.

```bash
cd ~/golden
export SSD=/dev/sdX

sha256sum -c golden-r36.4.7.img.zst.sha256          # master not rotten
lsblk -no TRAN ${SSD}                                # must be: usb

zstdcat golden-r36.4.7.img.zst | sudo dd of=${SSD} bs=64M status=progress conv=fsync
sync
```

### 4.3 (HOST) — **[NEW]** Verify the write

**First 3 units — full byte-for-byte readback** (~20 min):

```bash
RAW=$(cat golden.raw.size)
sudo dd if=${SSD} bs=1M count=$((RAW/1048576)) iflag=fullblock status=progress | sha256sum
cat golden.raw.sha256          # must match
```

**Remaining units — fast structural check** (~2 min):

```bash
sudo partprobe ${SSD}
sudo sgdisk -v ${SSD}                # GPT integrity, expect 0 problems
sudo e2fsck -fn ${SSD}1              # rootfs integrity, read-only
lsblk ${SSD}                         # expect 15 partitions
```

**If the target SSD is larger than 476.9 G**, the GPT backup header lands
mid-disk. `sgdisk -v` will say so. Fix:

```bash
sudo sgdisk -e ${SSD}
```

Then eject:

```bash
sudo udisksctl power-off -b ${SSD}
```

### 4.4 (ROBOT-N) — Install and boot

Install the SSD **into the robot it was flashed in** and power on. First boot is
slower — the keygen unit is generating host keys.

No personalization step. Hostname, username, and password are identical by
design.

### 4.5 (ROBOT-N) — Verify

```bash
# 1. right OS, from the right disk
cat /etc/nv_tegra_release | head -1        # R36 REVISION: 4.7
findmnt -no SOURCE /                       # /dev/nvme0n1p1  <-- NOT mmcblk0p1

# 2. [NEW] booted from NVMe, not the eMMC fallback
sudo efibootmgr | head -3                  # BootCurrent must equal the NVMe entry

# 3. [NEW] identity was regenerated
cat /etc/machine-id                        # non-empty, and unique per robot
ls /etc/ssh/ssh_host_*                     # 3 keypairs present
systemctl is-active ssh                    # active

# 4. payload
systemctl is-active rover-realsense.service
bash -ic "ros2 topic list" | grep -i camera
```

> **`findmnt -no SOURCE /` returning `/dev/mmcblk0p1` means you booted the
> eMMC factory OS.** Go back to 4.1a.

Record the serial in the build log:

```bash
tr -d '\0' < /proc/device-tree/serial-number; echo
```

---

## Before committing to 100 units

Run Phases 2–4 once, end to end, on a **spare SSD and spare Jetson**. A first
golden image almost always has one thing wrong with it. Find it on unit #2, not
unit #40.

Specifically confirm on that first clone:

1. SSH works without a console. ← the v1 blocker
2. `findmnt -no SOURCE /` shows `nvme0n1p1`. ← the eMMC trap
3. `/etc/machine-id` differs from ROVER-A's.

---

## Known behavior with an identical fleet

- **Two robots on one network discover each other's ROS 2 topics.** Expect
  duplicate/ghost topics when bench-testing two at once. Harmless in the field
  if they ship to separate sites.
- **Avahi/mDNS** auto-renames the second `rover.local` to `rover-2.local`.
  Cosmetic.
- **The WiFi PSK ships in the image.** `/etc/NetworkManager/system-connections/
  Rover.nmconnection` contains `psk=`. All 100 robots carry your WiFi password.
  A decision, not a bug — but make it consciously.
- No user SSH private keys or `authorized_keys` are present on ROVER-A, so
  nothing else leaks.

If topic collisions become a problem, the fix is a unique `ROS_DOMAIN_ID` per
robot in `~/.bashrc`. It does not require re-cutting the image.

---

## When to re-cut

Rebuild from Phase 1 whenever you change:

- JetPack / L4T version — QSPI firmware and rootfs must stay version-matched
- librealsense or `~/rover_workspace`
- Any system service meant to ship fleet-wide

Keep old images, named by content: `golden-r36.4.7-2026-07-29.img.zst`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| **SSH refused, robot otherwise fine** | keygen unit missing from image | Console in, run Step 1.4, re-cut. Check `systemctl status ssh` |
| **Boots to a stranger's desktop / oem-config** | Booted eMMC fallback; SSD serial ≠ UEFI entry | `findmnt -no SOURCE /`. Re-flash per 4.1 with that exact SSD |
| Black screen / UEFI shell | QSPI older than R36.4.7 | Redo 4.1 |
| `ALERT! PARTUUID=… does not exist` | Image written to `sdX1` instead of `sdX` | Rewrite with `of=/dev/sdX` |
| `sgdisk -v` warns backup GPT not at end | Target larger than source | `sudo sgdisk -e /dev/sdX` |
| `zerofree`: "filesystem is mounted" | Auto-mount | Step 2.3 |
| `zerofree`: "filesystem not clean" | Needs fsck | Step 2.4 |
| `dd`: "No space left on device" | Target smaller than source | Use an identical SSD model |
| `ros2: command not found` over SSH | `.bashrc` is interactive-only | `ssh host 'bash -ic "ros2 …"'` |
| Camera missing after clone | USB enumeration | `sudo /usr/local/sbin/reset_realsense_usb.sh` then `journalctl -u rover-realsense.service` |
| Host key warning on new robot | Expected — keys are new | `ssh-keygen -R <ip>` |

---

## Build log

| # | Date | Jetson serial | SSD serial | JetPack | Image written | Verified | Notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-07-29 | | P320WCB26020900029 | 6.2 | n/a | | ROVER-A (original) |
| 2 | | | | | | | first test clone |
| 3 | | | | | | | |

**[NEW] Record the SSD serial**, not just the Jetson serial — it is the pairing
that 4.1a depends on. Get it with:

```bash
sudo nvme id-ctrl /dev/nvme0n1 | grep -i '^sn'
```

---

## Quick reference

```bash
# ---- CAPTURE (HOST, SSD in reader; nvme* = this laptop, never a target) ----
export SSD=/dev/sdX
sudo blkid -s PARTUUID -o value ${SSD}1     # must be ddede667-4aba-4c6e-b591-91ca6f9cc05a
sudo umount ${SSD}?* 2>/dev/null
sudo e2fsck -f ${SSD}1
sudo zerofree -v ${SSD}1
cd ~/golden
sudo dd if=${SSD} bs=64M status=progress | zstd -T0 -9 > golden-r36.4.7.img.zst
sha256sum golden-r36.4.7.img.zst | tee golden-r36.4.7.img.zst.sha256
zstdcat golden-r36.4.7.img.zst | tee >(sha256sum | cut -d' ' -f1 > golden.raw.sha256) | wc -c > golden.raw.size

# ---- RESTORE (HOST, blank SSD already flashed in its own robot) ----
export SSD=/dev/sdX
sha256sum -c golden-r36.4.7.img.zst.sha256
lsblk -no TRAN ${SSD}                        # must be: usb
zstdcat golden-r36.4.7.img.zst | sudo dd of=${SSD} bs=64M status=progress conv=fsync
sync
sudo sgdisk -v ${SSD} && sudo e2fsck -fn ${SSD}1
sudo udisksctl power-off -b ${SSD}
```

---

## Appendix — alternative capture without removing the SSD

NVIDIA ships `Linux_for_Tegra/tools/backup_restore/l4t_backup_restore.sh`,
which backs up and restores the Jetson's storage over USB-C with the board in
recovery mode — no SSD removal, and it can include QSPI.

Worth evaluating if pulling 100 SSDs proves painful. Two cautions: it requires
the full R36.4.7 BSP on HOST, and restoring a captured QSPI image to a
different unit reinstates boot entries referencing the *original* drive serial
— which is the 4.1a failure mode. Validate on a spare before adopting.
