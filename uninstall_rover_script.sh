#!/bin/bash

#########################################################################
# Script Name	: Rover ROS2 Uninstall Script                           #
# Description	: Removes what setup_rover.sh installed                 #
# Author       	: Shashank Sharma                                       #
# Email         : shashank@roverrobotics.com                            #
#########################################################################

WORKSPACE_NAME=rover_workspace
WORKSPACE_DIR="$HOME/$WORKSPACE_NAME"

# Defined Colors
BOLDRED="\e[1;31m"
ENDCOLOR="\e[0m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BOLD="\e[1m"

print_boldred() { echo -e "$BOLDRED${1} $ENDCOLOR"; }
print_red()     { echo -e "$RED${1} $ENDCOLOR"; }
print_green()   { echo -e "$GREEN${1} $ENDCOLOR"; }
print_yellow()  { echo -e "$YELLOW${1} $ENDCOLOR"; }
print_bold()    { echo -e "$BOLD${1} $ENDCOLOR"; }

usage() {
    cat <<EOF_USAGE
Rover Robotics ROS 2 uninstall

Usage: ./uninstall_rover_script.sh [options]

With no options it removes everything setup_rover.sh set up on the system:
services and watchdogs, helper scripts, sudoers entries, udev rules, the
CAN module config, the Cyclone DDS and ROS_DOMAIN_ID settings, the GPS
service and its driver version hold, the install log and the workspace
line in ~/.bashrc. Your workspace, ROS 2 and NVIDIA software
are kept.

Also remove (each asks first unless -y):
      --workspace   ~/$WORKSPACE_NAME (source, build and install)
      --realsense   the librealsense SDK built from source in /usr/local, its udev
                    rules and build files, or the prebuilt packages and Intel's
                    apt source on x86
      --ros         ROS 2 (all ros-<distro>-* packages, colcon, rosdep), the ROS
                    apt source and keyring, and the ROS lines in ~/.bashrc
      --jetpack     NVIDIA JetPack and CUDA (nvidia-jetpack and everything it
                    pulled in) and the CUDA lines in ~/.bashrc. The L4T base
                    packages the Jetson boots from are never touched.
      --docker      Docker, which JetPack installs on JetPack 7, and its apt source
      --all         All of the above: back to the computer as it was before
                    ros2_installation.sh and setup_rover.sh
  -y, --yes         Do not ask
  -h, --help        Show this message
EOF_USAGE
}

DO_WORKSPACE=false; DO_REALSENSE=false; DO_ROS=false; DO_JETPACK=false; DO_DOCKER=false
ASSUME_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) DO_WORKSPACE=true ;;
        --realsense) DO_REALSENSE=true ;;
        --ros)       DO_ROS=true ;;
        --jetpack)   DO_JETPACK=true ;;
        --docker)    DO_DOCKER=true ;;
        --all)       DO_WORKSPACE=true; DO_REALSENSE=true; DO_ROS=true; DO_JETPACK=true; DO_DOCKER=true ;;
        -y|--yes)    ASSUME_YES=true ;;
        -h|--help)   usage; exit 0 ;;
        *) print_red "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    local yn
    while true; do
        printf "%s [y/n]: " "$1"
        read -r yn
        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

remove_files() {
    local f
    for f in "$@"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            if sudo rm -rf "$f"; then
                print_green "Removed $f"
            else
                print_red "Unable to remove $f"
            fi
        fi
    done
}

# Drop exact lines from a file, keeping everything else
remove_lines() {
    local file="$1"; shift
    local line tmp
    [ -f "$file" ] || return 0
    for line in "$@"; do
        grep -qxF "$line" "$file" || continue
        tmp=$(mktemp)
        { grep -vxF "$line" "$file" || true; } > "$tmp"
        if [ -w "$file" ]; then cat "$tmp" > "$file"; else sudo cp "$tmp" "$file"; fi
        rm -f "$tmp"
        print_green "Removed from $file: $line"
    done
}

#########################################################################
#                          UNINSTALL PROCESS                            #
#########################################################################

print_boldred "This removes the Rover Robotics services and system setup from this computer."
[ "$DO_WORKSPACE" = true ] && print_boldred "  + the workspace $WORKSPACE_DIR"
[ "$DO_REALSENSE" = true ] && print_boldred "  + the librealsense SDK"
[ "$DO_ROS" = true ]       && print_boldred "  + ROS 2"
[ "$DO_JETPACK" = true ]   && print_boldred "  + NVIDIA JetPack and CUDA"
[ "$DO_DOCKER" = true ]    && print_boldred "  + Docker"
[ "$DO_WORKSPACE" = false ] && print_boldred "The workspace is kept; add --workspace to remove it too."
confirm "Are you sure you would like to uninstall?" || { echo "Nothing was changed."; exit 0; }
sudo -v || { print_red "This needs sudo."; exit 1; }
echo ""

# --- services and watchdogs ------------------------------------------------
print_bold "Services"
units=(roverrobotics.service rover-realsense.service realsense-watchdog.timer realsense-watchdog.service
       rover-ublox.service gps-watchdog.timer gps-watchdog.service lo-multicast.service
       rover-bno055.service imu-watchdog.timer imu-watchdog.service
       can-watchdog.timer can-watchdog.service can.service)
for u in "${units[@]}"; do
    if [ -f "/etc/systemd/system/$u" ]; then
        sudo systemctl stop "$u" 2>/dev/null
        sudo systemctl disable "$u" 2>/dev/null
        remove_files "/etc/systemd/system/$u"
    fi
done
sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null

# --- helper scripts, sudoers, module and apt config -------------------------
print_bold "Helper scripts and system config"
remove_files /usr/sbin/roverrobotics /usr/sbin/enablecan /usr/sbin/can-watchdog /usr/sbin/can-selftest \
             /usr/sbin/realsense-watchdog /usr/local/sbin/realsense-probe \
             /usr/sbin/imu-watchdog /usr/local/sbin/imu-probe /usr/local/sbin/rover-imu-active \
             /var/log/rover-imu-events.log \
             /usr/local/sbin/reset_realsense_usb.sh /usr/local/sbin/reset_bno055_usb.sh \
             /usr/sbin/gps-watchdog /usr/local/sbin/gps-probe /usr/local/sbin/rover-gps-active \
             /usr/local/sbin/reset_ublox_usb.sh /etc/cyclonedds/rover.xml \
             /etc/sudoers.d/rover-realsense /etc/sudoers.d/rover-bno055 /etc/sudoers.d/rover-ublox \
             /etc/modules-load.d/gs_usb.conf /etc/apt/apt.conf.d/90rover-installer-lock-wait \
             "$HOME/rover_setup.log"

# --- udev rules -------------------------------------------------------------
reload_udev=false
for rule in 55-roverrobotics.rules 56-rover-ublox.rules 99-can-usb.rules; do
    if [ -f "/etc/udev/rules.d/$rule" ]; then
        remove_files "/etc/udev/rules.d/$rule"; reload_udev=true
    fi
done

# --- shell and environment ---------------------------------------------------
print_bold "Shell setup"
# absolute path now, ~ path in older versions
remove_lines "$HOME/.bashrc" "source ~/$WORKSPACE_NAME/install/setup.bash" \
                             "source $WORKSPACE_DIR/install/setup.bash" \
                             "export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp" \
                             "export CYCLONEDDS_URI=file:///etc/cyclonedds/rover.xml"
remove_lines /etc/environment "RMW_IMPLEMENTATION=rmw_cyclonedds_cpp" \
                              "CYCLONEDDS_URI=file:///etc/cyclonedds/rover.xml"
# setup_rover.sh writes one ROS_DOMAIN_ID line in each
mapfile -t domain_lines < <(grep -xE 'export ROS_DOMAIN_ID=[0-9]+' "$HOME/.bashrc" 2>/dev/null)
[ ${#domain_lines[@]} -gt 0 ] && remove_lines "$HOME/.bashrc" "${domain_lines[@]}"
mapfile -t domain_lines < <(grep -xE 'ROS_DOMAIN_ID=[0-9]+' /etc/environment 2>/dev/null)
[ ${#domain_lines[@]} -gt 0 ] && remove_lines /etc/environment "${domain_lines[@]}"

# the GPS driver package stays (ROS packages go with --ros); only the hold set by setup_rover.sh is released
held=$(apt-mark showhold 2>/dev/null | grep -E '^ros-[a-z]+-ublox-gps$')
for pkg in $held; do
    sudo apt-mark unhold "$pkg" >/dev/null && print_green "Released the version hold on $pkg"
done

# --- optional: workspace ----------------------------------------------------
if [ "$DO_WORKSPACE" = true ] && [ -d "$WORKSPACE_DIR" ]; then
    echo ""
    if confirm "Delete $WORKSPACE_DIR ($(du -sh "$WORKSPACE_DIR" 2>/dev/null | cut -f1))?"; then
        rm -rf "$WORKSPACE_DIR" && print_green "Removed $WORKSPACE_DIR"
    fi
fi

# --- optional: librealsense SDK ---------------------------------------------
if [ "$DO_REALSENSE" = true ]; then
    echo ""
    if confirm "Remove the librealsense SDK?"; then
        print_bold "librealsense"
        # built from source on a Jetson: no package owns these files
        remove_files /usr/local/lib/librealsense2.so* /usr/local/lib/librealsense2-gl.so* \
                     /usr/local/lib/librealsense-file.a /usr/local/lib/librsutils.a \
                     /usr/local/include/librealsense2 /usr/local/include/librealsense2-gl \
                     /usr/local/lib/cmake/realsense2 /usr/local/lib/cmake/realsense2-gl \
                     /usr/local/lib/pkgconfig/realsense2.pc /usr/local/lib/pkgconfig/realsense2-gl.pc \
                     /usr/local/bin/realsense-viewer /usr/local/bin/rs-* \
                     "$HOME/librealsense_build" "$HOME/libuvc_installation.sh"
        sudo ldconfig
        for rule in 99-realsense-libusb.rules 99-realsense-d4xx-mipi-dfu.rules; do
            if [ -f "/etc/udev/rules.d/$rule" ]; then
                remove_files "/etc/udev/rules.d/$rule"; reload_udev=true
            fi
        done
        # prebuilt packages on x86
        pkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'librealsense2*' 'ros-*-librealsense2' \
               'ros-*-realsense2-*' 2>/dev/null | awk '$1 ~ /^ii/ {print $2}')
        if [ -n "$pkgs" ]; then
            # shellcheck disable=SC2086
            sudo apt-get purge -y $pkgs && print_green "Removed packages: $(echo $pkgs)"
        fi
        remove_files /etc/apt/sources.list.d/librealsense.list /etc/apt/keyrings/librealsense.pgp
    fi
fi

# --- optional: ROS 2 ----------------------------------------------------------
if [ "$DO_ROS" = true ]; then
    distros=$(ls /opt/ros 2>/dev/null | tr '\n' ' ')
    echo ""
    if [ -n "$distros" ] && confirm "Remove ROS 2 ($distros)?"; then
        print_bold "ROS 2"
        for d in $distros; do
            sudo apt-get purge -y "ros-$d-*"
            remove_lines "$HOME/.bashrc" "source /opt/ros/$d/setup.bash"
        done
        for p in ros-dev-tools python3-colcon-common-extensions python3-colcon-clean python3-rosdep python3-vcstool; do
            dpkg -s "$p" >/dev/null 2>&1 && sudo apt-get purge -y "$p"
        done
        remove_lines "$HOME/.bashrc" "source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash"
        remove_files /etc/apt/sources.list.d/ros2.list /usr/share/keyrings/ros-archive-keyring.gpg \
                     /etc/ros/rosdep "$HOME/.ros" /opt/ros
    fi
fi

# --- optional: NVIDIA JetPack and CUDA --------------------------------------
if [ "$DO_JETPACK" = true ]; then
    echo ""
    if dpkg -s nvidia-jetpack >/dev/null 2>&1 && \
       confirm "Remove NVIDIA JetPack and CUDA (the L4T base packages stay)?"; then
        print_bold "JetPack and CUDA"
        # only the meta package; autoremove below takes what it pulled in
        sudo apt-get purge -y nvidia-jetpack
        # CUDA's Nsight tools are the only files ever placed in it; keep the standard directory
        sudo mkdir -p /usr/local/bin
        remove_lines "$HOME/.bashrc" 'export PATH=/usr/local/cuda/bin:$PATH' \
                                     'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH'
    fi
fi

# --- optional: Docker -------------------------------------------------------
if [ "$DO_DOCKER" = true ]; then
    echo ""
    if dpkg -s docker-ce >/dev/null 2>&1 && confirm "Remove Docker?"; then
        print_bold "Docker"
        sudo systemctl stop docker.service docker.socket containerd.service 2>/dev/null
        for p in docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin; do
            dpkg -s "$p" >/dev/null 2>&1 && sudo apt-get purge -y "$p"
        done
        remove_files /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
    fi
fi

# --- tidy up ------------------------------------------------------------------
if [ "$DO_ROS" = true ] || [ "$DO_JETPACK" = true ] || [ "$DO_DOCKER" = true ] || [ "$DO_REALSENSE" = true ]; then
    echo ""
    print_bold "Removing packages nothing needs any more"
    sudo apt-get autoremove --purge -y
    # config files of removed packages, and the downloaded .deb files (several GB after JetPack and ROS)
    rc=$(dpkg -l | awk '/^rc/ {print $2}')
    if [ -n "$rc" ]; then
        # shellcheck disable=SC2086
        sudo dpkg --purge $rc >/dev/null 2>&1 && print_green "Removed leftover config of: $(echo $rc)"
    fi
    sudo apt-get clean && print_green "Cleared the apt download cache"
    sudo apt-get update >/dev/null 2>&1
fi

if [ "$reload_udev" = true ]; then
    sudo udevadm control --reload-rules > /dev/null && sudo udevadm trigger > /dev/null && \
        print_green "Reloaded udev rules"
fi

echo ""
print_bold "Uninstall complete."
print_yellow "Reboot so the removed services, udev rules and environment settings are gone everywhere."
