#!/bin/bash
#########################################################################
# Script Name	: Rover ROS2 Install Script                             #
# Description	: Sets up ROS2 software for Rover Robots                #
# Author       	: Shashank Sharma                                       #
# Email         : shashank@roverrobotics.com                            #
#########################################################################

#########################################################################
#                          VARIABLES FOR SETUP                          #
#                     EDIT TO CHANGE REPO/ROS DISTRO                    #
#########################################################################

# ROS_DISTRO will be set dynamically based on Ubuntu version
# You can still override it manually later if needed.
ROVER_REPO=https://github.com/RoverRobotics/roverrobotics_ros2.git
IMU_REPO=https://github.com/flynneva/bno055.git
RPLIDAR_REPO=https://github.com/Slamtec/rplidar_ros.git
REALSENSE_ROS_REPO=https://github.com/IntelRealSense/realsense-ros.git
REALSENSE_ROS_BRANCH=ros2-master
WORKSPACE_NAME=rover_workspace
WORKSPACE_DIR="$HOME/$WORKSPACE_NAME"
ROVER_ROS2_DIR="$WORKSPACE_DIR/src/roverrobotics_ros2"

# Script location, not $PWD, so udev/ and docs/ resolve from any directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$SCRIPT_DIR"

CAN_IFACE=rovercan   # stable udev name; canN is not stable across boots
CAN_VID=1d50         # gs_usb: CANable / candleLight / InnoMaker USB2CAN V3.3
CAN_PID=606f
CAN_BITRATE=500000
CAN_DBITRATE=2000000

#########################################################################
#                          HELPER FUNCTIONS                             #
#########################################################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BOLD="\e[1m"
ITALICBLUE="\e[3;94m"
BOLDBLUE="\e[1;94m"
ENDCOLOR="\e[0m"

print_red() {
    echo -e "$RED${1} $ENDCOLOR"
}
print_green() {
    echo -e "$GREEN${1} $ENDCOLOR"
}
print_yellow() {
    echo -e "$YELLOW${1} $ENDCOLOR"
}
print_bold() {
    echo -e "$BOLD${1} $ENDCOLOR"
}
print_italic() {
    echo -e "$ITALICBLUE${1} $ENDCOLOR"
}
print_boldblue(){
    echo -e "$BOLDBLUE${1} $ENDCOLOR"
}
print_next_install() {
    install_number=$((install_number+1))
    print_bold "[$install_number/$install_total]: ${1}"
}

#########################################################################
#                          USAGE / ARGUMENTS                            #
#########################################################################
usage() {
    cat <<EOF_USAGE
Rover Robotics ROS 2 setup

Usage: ./setup_rover.sh [options]

With no options the script is fully interactive (whiptail menus when
available, plain prompts otherwise).

Options:
  -r, --robot TYPE     mini_2wd | mini | miti_65 | miti | zero | pro | max | mega
  -w, --max-wheel IN   MAX wheel size in inches: 13 | 15
                       (MAX only; selects the config and URDF)
  -g, --gamepad PAD    ps4 | ps5. Which controller the teleop launch uses.
  -d, --distro NAME    ROS 2 distro (humble, jazzy). Default: from Ubuntu version
      --with-imu       Install the BNO055 IMU repository
      --with-lidar     Install the RPLIDAR S2 repository
      --with-realsense Install Intel RealSense support (SDK + ROS wrapper)
      --no-realsense   Skip RealSense without being asked
      --with-rs-service  Install rover-realsense.service (implies --with-realsense)
      --with-service   Install the roverrobotics.service autostart unit
      --no-udev        Skip the udev rules (they are installed by default)
      --jp6            Force the JetPack 6 gamepad button/axis mapping
      --no-jp6         Force the stock gamepad button/axis mapping
  -y, --yes            Non-interactive. Accept defaults for anything not
                       given on the command line.
  -h, --help           Show this message

Examples:
  ./setup_rover.sh
  ./setup_rover.sh --robot miti --gamepad ps5 --with-service -y
  ./setup_rover.sh -r max -w 13 -g ps5 -d humble --with-imu -y
EOF_USAGE
}

ARG_ROBOT=""
ARG_DISTRO=""
ARG_IMU=""
ARG_LIDAR=""
ARG_UDEV=""
ARG_SERVICE=""
ARG_JP6=""
ARG_MAXWHEEL=""
ARG_GAMEPAD=""
ARG_REALSENSE=""
ARG_RS_SERVICE=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--robot)    ARG_ROBOT="${2:-}"; shift 2 ;;
        -w|--max-wheel) ARG_MAXWHEEL="${2:-}"; shift 2 ;;
        -g|--gamepad)  ARG_GAMEPAD="${2:-}"; shift 2 ;;
        -d|--distro)   ARG_DISTRO="${2:-}"; shift 2 ;;
        --with-imu)    ARG_IMU=true; shift ;;
        --with-lidar)  ARG_LIDAR=true; shift ;;
        --with-realsense) ARG_REALSENSE=true; shift ;;
        --no-realsense)   ARG_REALSENSE=false; shift ;;
        --with-rs-service) ARG_REALSENSE=true; ARG_RS_SERVICE=true; shift ;;
        --with-service) ARG_SERVICE=true; shift ;;
        --no-udev)     ARG_UDEV=false; shift ;;
        --jp6)         ARG_JP6=true; shift ;;
        --no-jp6)      ARG_JP6=false; shift ;;
        -y|--yes)      ASSUME_YES=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) print_red "Unknown option: $1"; echo ""; usage; exit 1 ;;
    esac
done

#########################################################################
#                    DETECT UBUNTU & SUGGEST ROS2 DISTRO                #
#########################################################################
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_VERSION="$VERSION_ID"
else
    UBUNTU_VERSION=""
fi

SUGGESTED_ROS_DISTRO=""
case "$UBUNTU_VERSION" in
    "22.04")
        SUGGESTED_ROS_DISTRO="humble"
        ;;
    "24.04")
        SUGGESTED_ROS_DISTRO="jazzy"
        ;;
    *)
        # Fallback suggestion; user can override
        SUGGESTED_ROS_DISTRO="humble"
        ;;
esac

echo "Detected Ubuntu version: ${UBUNTU_VERSION:-unknown}"

if [ -n "$ARG_DISTRO" ]; then
    ROS_DISTRO="$ARG_DISTRO"
elif [ "$ASSUME_YES" = true ]; then
    ROS_DISTRO="$SUGGESTED_ROS_DISTRO"
else
    while true; do
        if [ -n "$SUGGESTED_ROS_DISTRO" ]; then
            read -p "Suggested ROS 2 distribution is '${SUGGESTED_ROS_DISTRO}'. Use this? [Y/n]: " yn
            case "$yn" in
                [Yy]|"" )
                    ROS_DISTRO="$SUGGESTED_ROS_DISTRO"
                    break
                    ;;
                [Nn] )
                    read -p "Enter ROS 2 distribution to use (e.g. humble, jazzy): " ROS_DISTRO
                    [ -n "$ROS_DISTRO" ] && break
                    ;;
                * )
                    echo "Please answer yes or no."
                    ;;
            esac
        else
            read -p "Could not determine Ubuntu version. Enter ROS 2 distribution to use (e.g. humble, jazzy): " ROS_DISTRO
            [ -n "$ROS_DISTRO" ] && break
        fi
    done
fi

echo "Using ROS 2 distribution: $ROS_DISTRO"
echo ""

# Fail early rather than printing a dozen "package not found" lines later
if [ ! -d "/opt/ros/$ROS_DISTRO" ]; then
    print_red "ROS 2 '$ROS_DISTRO' is not installed (/opt/ros/$ROS_DISTRO not found)."
    echo ""
    echo "Install it first:"
    echo "    ./ros2_installation.sh"
    echo ""
    echo "Or pass a distro that is installed:  ./setup_rover.sh --distro <name>"
    echo "Installed distros: $(ls /opt/ros 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

#########################################################################
#                DETECT PLATFORM (JETSON / L4T / JETPACK 6)             #
#########################################################################
# Everything below works on Intel/AMD x86, Raspberry Pi and Jetson alike;
# these two flags only select the parts that genuinely differ.
#   IS_TEGRA -> gs_usb must be built (L4T ships none; mainline kernels do),
#               and librealsense must be built from source (no arm64 debs)
#   IS_JP6   -> use the _jp6 gamepad map (JP6 joydev order differs)
IS_TEGRA=false
IS_JP6=false
L4T_RELEASE=""
if [ -f /etc/nv_tegra_release ]; then
    IS_TEGRA=true
    # "# R36 (release), REVISION: 3.0, GCID: ..."
    L4T_RELEASE=$(head -n1 /etc/nv_tegra_release | grep -o '^# R[0-9]\+' | grep -o '[0-9]\+')
    if [ -n "$L4T_RELEASE" ] && [ "$L4T_RELEASE" -ge 36 ]; then
        IS_JP6=true
    fi
fi

if [ "$IS_TEGRA" = true ]; then
    PLATFORM_DESC="Jetson (L4T R${L4T_RELEASE:-?}, $(uname -m))"
else
    PLATFORM_DESC="$(uname -m) (non-Jetson)"
fi
echo "Detected platform: $PLATFORM_DESC"

# Packages that the script will check/install
packages=(
    "ros-$ROS_DISTRO-slam-toolbox"
    "ros-$ROS_DISTRO-navigation2"
    "ros-$ROS_DISTRO-nav2-bringup"
    "ros-$ROS_DISTRO-robot-localization"
    "ros-$ROS_DISTRO-robot-state-publisher"
    "ros-$ROS_DISTRO-joint-state-publisher"
    "ros-$ROS_DISTRO-xacro"
    "ros-$ROS_DISTRO-joy-linux"
    "python3-serial"
    "python3-smbus"
    "git"
    "net-tools"
    "setserial"    # 55-roverrobotics.rules RUN+= needs it
    "can-utils"    # candump / cansend
)

print_install_settings() {
    print_bold "====================================="
    print_boldblue "                                     "
    print_bold "Installation settings:               "
    print_bold "----------------------------         "
    print_boldblue "Platform:      $PLATFORM_DESC       "
    print_boldblue "Robot type:    $device_type          "
    [ "$device_type" = "max" ] && \
    print_boldblue "MAX wheels:    $max_variant          "
    print_boldblue "Controller:    $gamepad              "
    print_boldblue "JP6 pad map:   $use_jp6              "
    print_boldblue "ROS 2 Distro:  $ROS_DISTRO           "
    print_boldblue "Workspace:     $WORKSPACE_DIR        "
    print_boldblue "Repo install:  $install_repo         "
    print_boldblue "Service:       $install_service      "
    print_boldblue "Udev:          $install_udev         "
    print_boldblue "CAN iface:     $CAN_IFACE            "
    print_boldblue "BNO055 IMU:    $install_imu          "
    print_boldblue "RPLidar S2:    $install_s2           "
    print_boldblue "RealSense:     $install_realsense_opt (service: $install_rs_service)"
    print_boldblue "                                     "
    print_bold "====================================="
    echo ""
}

# UI helper: use whiptail if available, otherwise fall back to plain read
if command -v whiptail >/dev/null 2>&1 && [ "$ASSUME_YES" != true ]; then
    USE_WHIPTAIL=true
else
    USE_WHIPTAIL=false
fi

ask_yes_no() {
    # Usage: ask_yes_no "Question text" default_yes_or_no result_var_name
    local question="$1"
    local default="$2"   # "yes" or "no"
    local __resultvar="$3"
    local answer

    if [ "$ASSUME_YES" = true ]; then
        answer="$default"
    elif [ "$USE_WHIPTAIL" = true ]; then
        local height=10
        local width=70
        if [ "$default" = "no" ]; then
            whiptail --title "Rover Setup" --defaultno --yesno "$question" $height $width
        else
            whiptail --title "Rover Setup" --yesno "$question" $height $width
        fi
        local exitstatus=$?
        if [ $exitstatus -eq 0 ]; then
            answer="yes"
        else
            answer="no"
        fi
    else
        # Fallback to CLI
        while true; do
            if [ "$default" = "no" ]; then
                read -p "$question [y/N]: " yn
                yn=${yn:-n}
            else
                read -p "$question [Y/n]: " yn
                yn=${yn:-y}
            fi
            case "$yn" in
                [Yy]* ) answer="yes"; break ;;
                [Nn]* ) answer="no"; break ;;
                * ) echo "Please answer yes or no." ;;
            esac
        done
    fi

    if [ "$answer" = "yes" ]; then
        eval "$__resultvar=true"
    else
        eval "$__resultvar=false"
    fi
}

select_robot_type() {
    # Honour --robot without prompting.
    if [ -n "$ARG_ROBOT" ]; then
        case "$ARG_ROBOT" in
            mini_2wd|mini|miti_65|miti|zero|pro|max|mega) device_type="$ARG_ROBOT"; return ;;
            *) print_red "Unknown robot type: $ARG_ROBOT"; usage; exit 1 ;;
        esac
    fi

    if [ "$ASSUME_YES" = true ]; then
        print_red "--yes requires --robot TYPE (there is no safe default robot)."
        exit 1
    fi

    if [ "$USE_WHIPTAIL" = true ]; then
        choice=$(
            whiptail --title "Select Rover Type" --menu "Choose your robot: (Use Arrow Keys to Navigate and Enter Key to Select)" 18 60 8 \
                "1" "Mini 2WD" \
                "2" "Mini (4WD)" \
                "3" "Miti 65" \
                "4" "Miti" \
                "5" "Zero" \
                "6" "Pro" \
                "7" "Max" \
                "8" "Mega" \
                3>&1 1>&2 2>&3
        )
        [ $? -ne 0 ] && echo "Cancelled." && exit 1

        case "$choice" in
            1) device_type="mini_2wd" ;;
            2) device_type="mini" ;;
            3) device_type="miti_65" ;;
            4) device_type="miti" ;;
            5) device_type="zero" ;;
            6) device_type="pro" ;;
            7) device_type="max" ;;
            8) device_type="mega" ;;
        esac

    else
        # fallback CLI menu
        while true; do
            echo "Select Rover Type:"
            echo "1) Mini 2WD"
            echo "2) Mini (4WD)"
            echo "3) Miti 65"
            echo "4) Miti"
            echo "5) Zero"
            echo "6) Pro"
            echo "7) Max"
            echo "8) Mega"
            read -p "Enter choice: " choice

            case "$choice" in
                1) device_type="mini_2wd"; break ;;
                2) device_type="mini"; break ;;
                3) device_type="miti_65"; break ;;
                4) device_type="miti"; break ;;
                5) device_type="zero"; break ;;
                6) device_type="pro"; break ;;
                7) device_type="max"; break ;;
                8) device_type="mega"; break ;;
                *) echo "Invalid choice." ;;
            esac
        done
    fi
}

# MAX wheel size -> config + URDF. Wrong radius silently scales odometry.
#   13in max_130 (r 0.1651) | 15in max_150 (r 0.1905, upstream default)
# max_65 / max_100 are being phased out and are not offered here; their
# configs still ship in the repo if you need them.
select_max_variant() {
    max_variant=""

    if [ -n "$ARG_MAXWHEEL" ]; then
        case "$ARG_MAXWHEEL" in
            13|130|max_130)  max_variant="max_130" ;;
            15|150|max_150)  max_variant="max_150" ;;
            *) print_red "Unknown MAX wheel size: $ARG_MAXWHEEL (use 13 or 15)"; exit 1 ;;
        esac
        return
    fi

    if [ "$ASSUME_YES" = true ]; then
        print_red "--yes with --robot max requires --max-wheel (13 or 15)."
        exit 1
    fi

    if [ "$USE_WHIPTAIL" = true ]; then
        choice=$(
            whiptail --title "Select MAX Wheel Size" --menu "Which wheels are fitted to this MAX?\n(Use Arrow Keys to Navigate and Enter Key to Select)" 16 66 2 \
                "1" "13 inch   (max_130)" \
                "2" "15 inch   (max_150)" \
                3>&1 1>&2 2>&3
        )
        [ $? -ne 0 ] && echo "Cancelled." && exit 1
        case "$choice" in
            1) max_variant="max_130" ;;
            2) max_variant="max_150" ;;
        esac
    else
        while true; do
            echo "Which wheels are fitted to this MAX?"
            echo "1) 13 inch   (max_130)"
            echo "2) 15 inch   (max_150)"
            read -p "Enter choice: " choice
            case "$choice" in
                1) max_variant="max_130"; break ;;
                2) max_variant="max_150"; break ;;
                *) echo "Invalid choice." ;;
            esac
        done
    fi
}

# Upstream hardcodes ps4_controller.launch.py in every *_teleop.launch.py
select_gamepad() {
    if [ -n "$ARG_GAMEPAD" ]; then
        case "${ARG_GAMEPAD,,}" in
            ps4) gamepad="ps4"; return ;;
            ps5) gamepad="ps5"; return ;;
            *) print_red "Unknown gamepad: $ARG_GAMEPAD (use ps4 or ps5)"; exit 1 ;;
        esac
    fi

    if [ "$ASSUME_YES" = true ]; then
        gamepad="ps4"
        return
    fi

    if [ "$USE_WHIPTAIL" = true ]; then
        choice=$(
            whiptail --title "Select Controller" --menu "Which controller will you drive this rover with?\n(Use Arrow Keys to Navigate and Enter Key to Select)" 16 66 2 \
                "1" "PS4 / DualShock 4" \
                "2" "PS5 / DualSense" \
                3>&1 1>&2 2>&3
        )
        [ $? -ne 0 ] && echo "Cancelled." && exit 1
        case "$choice" in
            1) gamepad="ps4" ;;
            2) gamepad="ps5" ;;
        esac
    else
        while true; do
            echo "Which controller will you drive this rover with?"
            echo "1) PS4 / DualShock 4"
            echo "2) PS5 / DualSense"
            read -p "Enter choice: " choice
            case "$choice" in
                1) gamepad="ps4"; break ;;
                2) gamepad="ps5"; break ;;
                *) echo "Invalid choice." ;;
            esac
        done
    fi
}

# RealSense install differs by platform, so ask separately from the service.
select_realsense() {
    if [ -n "$ARG_REALSENSE" ]; then
        install_realsense_opt="$ARG_REALSENSE"
    elif [ "$ASSUME_YES" = true ]; then
        install_realsense_opt=false
    else
        ask_yes_no "Install the Intel RealSense camera support (D435i etc.)?\n\nOn a Jetson this builds the librealsense SDK from source and can take ~45 minutes.\nOn x86 it installs Intel's prebuilt packages and is quick." no install_realsense_opt
    fi

    install_rs_service=false
    [ "$install_realsense_opt" != true ] && return

    if [ -n "$ARG_RS_SERVICE" ]; then
        install_rs_service="$ARG_RS_SERVICE"
    elif [ "$ASSUME_YES" = true ]; then
        install_rs_service=false
    else
        ask_yes_no "Install rover-realsense.service to start the camera at boot?\n\nIt power-cycles the camera over USB before each start, which recovers\nfrom the enumeration failures the D435i is prone to." yes install_rs_service
    fi
}

# librealsense SDK. Intel ships prebuilt debs for x86 only; there is no arm64
# build in their apt repo, so a Jetson has to build from source (with CUDA when
# available).
install_librealsense() {
    if [ "$IS_TEGRA" = true ]; then
        print_italic "  Jetson detected: building librealsense from source"

        if command -v realsense-viewer >/dev/null 2>&1; then
            ask_yes_no "librealsense already appears installed.\nRebuild it (~45 minutes)?" no rs_rebuild
            if [ "$rs_rebuild" != true ]; then
                print_green "  keeping the existing librealsense install"
                return 0
            fi
        fi

        print_yellow "  Unplug the RealSense camera before the SDK build."
        if [ "$ASSUME_YES" != true ]; then
            ask_yes_no "Camera unplugged, continue?" yes rs_go
            [ "$rs_go" != true ] && { print_yellow "  RealSense SDK build skipped"; return 1; }
        fi

        for p in libssl-dev libusb-1.0-0-dev libudev-dev libgtk-3-dev libglfw3-dev \
                 libgl1-mesa-dev libglu1-mesa-dev at libomp-dev cmake wget; do
            sudo apt-get install -y "$p" >/dev/null 2>&1
        done

        local cuda=off
        if command -v nvcc >/dev/null 2>&1 || [ -d /usr/local/cuda ]; then
            cuda=on
            print_green "  CUDA found, building with CUDA support"
        else
            print_yellow "  CUDA not found, building without it"
        fi

        cd "$HOME" || return 1
        wget -qO libuvc_installation.sh \
            https://github.com/IntelRealSense/librealsense/raw/master/scripts/libuvc_installation.sh || {
            print_red "  Could not download libuvc_installation.sh"; return 1; }

        sed -i "s|cmake \\.\\./.*|cmake ../ -DFORCE_LIBUVC=true -DCMAKE_BUILD_TYPE=release -DBUILD_EXAMPLES=true -DBUILD_GRAPHICAL_EXAMPLES=true -DBUILD_WITH_CUDA=$cuda|" \
            libuvc_installation.sh

        # Intel's script prompts "Remove all RealSense cameras attached" whenever
        # /dev/video* exists, and runs under 'bash -xe'. With stdin closed the
        # read returns EOF and -e kills the build in seconds. With FORCE_LIBUVC
        # the build never touches the kernel uvc driver, so neutralize it.
        sed -i 's|^\([[:space:]]*\)read -p .*|\1true|' libuvc_installation.sh
        if grep -q '^[[:space:]]*read ' libuvc_installation.sh; then
            print_yellow "  libuvc_installation.sh still has a prompt; upstream may have changed"
        fi

        chmod +x ./libuvc_installation.sh
        print_italic "  building librealsense (this can take ~45 minutes)..."
        if ./libuvc_installation.sh; then
            print_green "  librealsense installed. You can plug the camera back in."
        else
            print_red "  librealsense build failed. Verify with: realsense-viewer"
            return 1
        fi
    else
        print_italic "  Non-Jetson: installing prebuilt librealsense packages"

        # The ROS 2 apt repo carries librealsense2 for humble and jazzy on
        # amd64 and is already configured by ros2_installation.sh, so try it
        # first, so no extra keyring and no codename guessing.
        if sudo apt-get install -y "ros-$ROS_DISTRO-librealsense2" >/dev/null 2>&1; then
            print_green "  ros-$ROS_DISTRO-librealsense2 installed from the ROS repo"
            return 0
        fi

        print_yellow "  Not in the ROS repo for $ROS_DISTRO; trying Intel's apt repo"

        local codename
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        sudo mkdir -p /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/librealsense.pgp ]; then
            curl -fsSL https://librealsense.intel.com/Debian/librealsense.pgp \
                | sudo tee /etc/apt/keyrings/librealsense.pgp >/dev/null || {
                print_red "  Could not fetch the Intel signing key"; return 1; }
        fi

        echo "deb [signed-by=/etc/apt/keyrings/librealsense.pgp] https://librealsense.intel.com/Debian/apt-repo $codename main" \
            | sudo tee /etc/apt/sources.list.d/librealsense.list >/dev/null

        sudo apt-get update >/dev/null 2>&1
        if sudo apt-get install -y librealsense2-utils librealsense2-dev >/dev/null 2>&1; then
            print_green "  librealsense2 installed from Intel's repo"
        else
            print_red "  Could not install librealsense2 for Ubuntu '$codename'."
            print_red "  Intel does not publish a build for every release. Options:"
            print_red "    - build from source: https://github.com/IntelRealSense/librealsense"
            print_red "    - or use a release Intel supports (jammy)"
            sudo rm -f /etc/apt/sources.list.d/librealsense.list
            sudo apt-get update >/dev/null 2>&1
            return 1
        fi
    fi
    return 0
}

# ROS 2 wrapper. On x86 the prebuilt realsense2-camera package matches the apt
# SDK; on Jetson it has to be built against the source SDK.
install_realsense_ros() {
    if [ "$IS_TEGRA" != true ] && \
       sudo apt-get install -y "ros-$ROS_DISTRO-realsense2-camera" >/dev/null 2>&1; then
        print_green "  ros-$ROS_DISTRO-realsense2-camera installed from apt"
        return 0
    fi

    print_italic "  building realsense-ros in the workspace"
    mkdir -p "$WORKSPACE_DIR/src"
    clone_or_update "$REALSENSE_ROS_REPO" "$REALSENSE_ROS_BRANCH" \
                    "$WORKSPACE_DIR/src/realsense-ros"
}

create_realsense_service() {
    sudo tee /usr/local/sbin/reset_realsense_usb.sh >/dev/null <<'EOF_RSRESET'
#!/bin/bash
# Power-cycle the RealSense over USB before the camera node starts, to recover
# from the enumeration failures the D435i is prone to. Always exits 0: no
# camera fitted must not stop the service from trying.
for dev in /sys/bus/usb/devices/*/product; do
  if grep -qi "RealSense" "$dev" 2>/dev/null; then
    usb_path=$(dirname "$dev")
    auth_file="${usb_path}/authorized"
    if [ -w "$auth_file" ]; then
      echo 0 > "$auth_file"
      sleep 1
      echo 1 > "$auth_file"
      echo "reset_realsense_usb: power-cycled $(basename "$usb_path")"
    fi
  fi
done
exit 0
EOF_RSRESET
    sudo chmod +x /usr/local/sbin/reset_realsense_usb.sh

    # The unit runs 'sudo -n' as $USER, which fails without a NOPASSWD rule.
    # Scoped to this one script rather than a blanket grant.
    echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/reset_realsense_usb.sh" \
        | sudo tee /etc/sudoers.d/rover-realsense >/dev/null
    sudo chmod 0440 /etc/sudoers.d/rover-realsense
    if ! sudo visudo -cf /etc/sudoers.d/rover-realsense >/dev/null 2>&1; then
        sudo rm -f /etc/sudoers.d/rover-realsense
        print_yellow "  sudoers drop-in failed validation and was removed;"
        print_yellow "  the service will not be able to reset the camera over USB."
    fi

    sudo tee /etc/systemd/system/rover-realsense.service >/dev/null <<EOF_RSSVC
[Unit]
Description=Intel RealSense camera ROS 2 node
Wants=network-online.target
After=network-online.target
# no burst cap: tripping it would leave the camera down until someone noticed
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Environment=HOME=$HOME
WorkingDirectory=$HOME
# leading '-' so a missing sudoers rule cannot stop the camera starting at all
ExecStartPre=-/usr/bin/sudo -n /usr/local/sbin/reset_realsense_usb.sh
ExecStart=/bin/bash -c 'source /opt/ros/$ROS_DISTRO/setup.bash && source $WORKSPACE_DIR/install/setup.bash && exec ros2 launch realsense2_camera rs_launch.py'
Restart=always
# every restart re-runs the USB reset, so keep some distance between attempts
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_RSSVC

    sudo systemctl daemon-reload
    sudo systemctl enable rover-realsense.service
}

# Clone, or update in place. Plain `git clone` fails when the dir exists.
clone_or_update() {
    local url="$1"
    local branch="$2"     # may be empty for the repo default
    local dest="$3"
    local name
    name="$(basename "$dest")"

    if [ -d "$dest/.git" ]; then
        print_italic "  $name already present, updating"
        git -C "$dest" fetch --all --prune >/dev/null 2>&1
        if [ -n "$branch" ]; then
            git -C "$dest" checkout "$branch" >/dev/null 2>&1
        fi
        if git -C "$dest" pull --ff-only >/dev/null 2>&1; then
            print_green "  Updated $name"
        else
            print_yellow "  Could not fast-forward $name (local changes?). Left as-is."
        fi
        return 0
    fi

    if [ -d "$dest" ]; then
        print_yellow "  $dest exists but is not a git repository. Leaving it alone."
        return 1
    fi

    if [ -n "$branch" ]; then
        git clone "$url" -b "$branch" "$dest" >/dev/null 2>&1
    else
        git clone "$url" "$dest" >/dev/null 2>&1
    fi

    if [ $? -ne 0 ]; then
        print_red "  Failed to clone $name${branch:+ (branch: $branch)}"
        return 1
    fi
    print_green "  Successfully cloned $name"
    return 0
}

# Configs ship device_port: "can0"; follow the udev rename. Local edit --
# a later `git pull` reverts it.
patch_device_port() {
    local cfgdir="$ROVER_ROS2_DIR/roverrobotics_driver/config"
    local patched=0

    [ -d "$cfgdir" ] || return 0

    # Only the CAN robots. mini_2wd / zero / pro use /dev/rover-* serial ports.
    for f in miti_config.yaml miti_65_config.yaml mini_config.yaml \
             mega_config.yaml max_65_config.yaml max_100_config.yaml \
             max_130_config.yaml max_150_config.yaml; do
        [ -f "$cfgdir/$f" ] || continue
        if grep -q 'device_port: *"can0"' "$cfgdir/$f"; then
            # line-scoped, so the trailing comment is fixed too
            sed -i "/device_port:/ s|\"can0\"|\"$CAN_IFACE\"|g" "$cfgdir/$f"
            patched=$((patched+1))
        fi
    done

    if [ "$patched" -gt 0 ]; then
        print_green "  Set device_port to \"$CAN_IFACE\" in $patched config file(s)"
    else
        print_italic "  device_port already set (or no CAN configs found)"
    fi
}

# Upstream hardcodes max_150 for both URDF and config. Matching max_<digits>
# keeps re-runs idempotent; _neo (different chassis) is left alone.
patch_max_launch() {
    local lf="$ROVER_ROS2_DIR/roverrobotics_driver/launch/max.launch.py"
    local cfgdir="$ROVER_ROS2_DIR/roverrobotics_driver/config"
    local urdfdir="$ROVER_ROS2_DIR/roverrobotics_description/urdf"

    [ -f "$lf" ] || { print_yellow "  max.launch.py not found, skipping"; return; }

    if [ ! -f "$cfgdir/${max_variant}_config.yaml" ]; then
        print_red "  ${max_variant}_config.yaml not found in the repo; leaving max.launch.py alone"
        return
    fi
    if [ ! -f "$urdfdir/${max_variant}.urdf" ]; then
        print_red "  ${max_variant}.urdf not found in the repo; leaving max.launch.py alone"
        return
    fi

    if grep -q "urdf/max_[0-9]\+\.urdf" "$lf"; then
        sed -i "s|urdf/max_[0-9]\+\.urdf|urdf/${max_variant}.urdf|" "$lf"
        print_green "  URDF   -> ${max_variant}.urdf"
    else
        print_yellow "  max.launch.py URDF path was hand-edited; left as-is"
    fi

    if grep -q "'max_[0-9]\+_config\.yaml'" "$lf"; then
        sed -i "s|'max_[0-9]\+_config\.yaml'|'${max_variant}_config.yaml'|" "$lf"
        print_green "  Config -> ${max_variant}_config.yaml"
    else
        print_yellow "  max.launch.py config path was hand-edited; left as-is"
    fi
}

# All teleop launches, not just this robot's, so the choice holds either way
patch_teleop_gamepad() {
    local lfdir="$ROVER_ROS2_DIR/roverrobotics_driver/launch"
    local other patched=0

    [ -d "$lfdir" ] || { print_yellow "  launch directory not found, skipping"; return; }

    if [ "$gamepad" = "ps5" ]; then other="ps4"; else other="ps5"; fi

    for lf in "$lfdir"/*_teleop.launch.py; do
        [ -f "$lf" ] || continue
        if grep -q "/${other}_controller.launch.py" "$lf"; then
            sed -i "s|/${other}_controller.launch.py|/${gamepad}_controller.launch.py|g" "$lf"
            patched=$((patched+1))
        fi
    done

    if [ "$patched" -gt 0 ]; then
        print_green "  Set $patched teleop launch file(s) to ${gamepad}_controller.launch.py"
    else
        print_italic "  Teleop launches already use ${gamepad}_controller.launch.py"
    fi
}

# cp, not rm+mv, so the _jp6 sources survive a re-run. Backups live outside
# the repo: CMakeLists does install(DIRECTORY config), which would copy them.
JP6_BACKUP_DIR="$WORKSPACE_DIR/.rover_setup_backup"

apply_jp6_configs() {
    local cfgdir="$ROVER_ROS2_DIR/roverrobotics_driver/config"

    [ -d "$cfgdir" ] || { print_yellow "  Config directory not found, skipping gamepad map"; return; }
    mkdir -p "$JP6_BACKUP_DIR"

    for pad in ps4 ps5; do
        local src="$cfgdir/${pad}_controller_config_jp6.yaml"
        local dst="$cfgdir/${pad}_controller_config.yaml"
        local bak="$JP6_BACKUP_DIR/${pad}_controller_config.yaml.stock"

        if [ ! -f "$src" ]; then
            print_yellow "  ${pad}_controller_config_jp6.yaml not found, skipping"
            continue
        fi
        # taken once only, so a re-run cannot back up an already-patched file
        [ -f "$dst" ] && [ ! -f "$bak" ] && cp "$dst" "$bak"
        cp "$src" "$dst"
        print_green "  Applied JetPack 6 map to ${pad}_controller_config.yaml"
    done
}

restore_stock_configs() {
    local cfgdir="$ROVER_ROS2_DIR/roverrobotics_driver/config"
    local restored=0

    for pad in ps4 ps5; do
        local dst="$cfgdir/${pad}_controller_config.yaml"
        local bak="$JP6_BACKUP_DIR/${pad}_controller_config.yaml.stock"
        if [ -f "$bak" ]; then
            cp "$bak" "$dst"
            restored=$((restored+1))
        fi
    done

    [ "$restored" -gt 0 ] && print_green "  Restored the stock gamepad map ($restored file(s))"
    return 0
}

# Define the install service functions
create_startup_script() {
    local robot_type=$1
    # absolute paths: systemd does not expand ~ or read .bashrc
    cat << EOF2 | sudo tee /usr/sbin/roverrobotics
#!/bin/bash
# Both 'source' steps must run in the same shell as ros2 launch.

ROS_SETUP=/opt/ros/$ROS_DISTRO/setup.bash
WS_SETUP=$WORKSPACE_DIR/install/setup.bash

for f in "\$ROS_SETUP" "\$WS_SETUP"; do
  if [ ! -f "\$f" ]; then
    echo "roverrobotics: \$f not found, workspace not built?" >&2
    exit 1
  fi
done

source "\$ROS_SETUP"
source "\$WS_SETUP"

# exec so systemd supervises ros2 launch, not a wrapper shell
exec ros2 launch roverrobotics_driver ${robot_type}_teleop.launch.py
EOF2

    sudo chmod +x /usr/sbin/roverrobotics
}

create_startup_service() {
    cat << EOF3 | sudo tee /etc/systemd/system/roverrobotics.service
[Unit]
Description=Rover Robotics $device_type driver
# ordered after can.service: the driver cannot open the bus before it exists
After=can.service network.target
Wants=can.service
# no burst cap; RestartSec below is the backoff
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Environment=HOME=$HOME
ExecStart=/bin/bash /usr/sbin/roverrobotics
# always, not on-failure: a clean exit has still stopped driving the robot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF3

    sudo systemctl daemon-reload
    sudo systemctl enable roverrobotics.service
}

create_can_service() {
    # udev rule first: stable name by USB VID:PID
    sudo tee /etc/udev/rules.d/99-can-usb.rules >/dev/null <<EOF_CANUDEV
# Give the USB-CAN adapter a stable name. 1d50:606f = gs_usb (CANable etc).
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="$CAN_VID", ATTRS{idProduct}=="$CAN_PID", NAME="$CAN_IFACE"
EOF_CANUDEV
    sudo udevadm control --reload-rules >/dev/null 2>&1

    # gs_usb: only Jetson needs anything here. Mainline kernels (x86, Pi) ship
    # it and autoload from the USB modalias; L4T does not ship it at all.
    if [ "$IS_TEGRA" = true ]; then
        if modinfo gs_usb >/dev/null 2>&1; then
            # not always autoloaded on L4T, so pin it at boot
            sudo tee /etc/modules-load.d/gs_usb.conf >/dev/null <<'EOF_GSUSB'
#gs_usb module
gs_usb
EOF_GSUSB
            sudo modprobe gs_usb 2>/dev/null
            CAN_MODULE_OK=true
        else
            CAN_MODULE_OK=false
        fi
    else
        if modinfo gs_usb >/dev/null 2>&1; then
            sudo modprobe gs_usb 2>/dev/null
            CAN_MODULE_OK=true
        else
            CAN_MODULE_OK=false
        fi
    fi

    # rename now rather than at reboot; cannot rename an interface while up
    local _i _drv
    for _i in $(ip -brief link show type can 2>/dev/null | awk '{print $1}'); do
        _drv=$(basename "$(readlink -f "/sys/class/net/$_i/device/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$_drv" = "gs_usb" ] && [ "$_i" != "$CAN_IFACE" ]; then
            sudo ip link set down "$_i" 2>/dev/null
            sudo udevadm trigger --action=add --subsystem-match=net 2>/dev/null
            sleep 2
        fi
    done

    cat << EOF4 | sudo tee /usr/sbin/enablecan
#!/bin/bash
# Bring up the rover's USB-CAN adapter.
# IFACE is the udev name from 99-can-usb.rules, not a kernel canN name.
IFACE=$CAN_IFACE
BITRATE=$CAN_BITRATE
DBITRATE=$CAN_DBITRATE
VID=$CAN_VID
PID=$CAN_PID
reset_done=0

# root under systemd, sudo when run by hand; unconditional sudo hangs on a
# shell with no tty
if [ "\$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# USB-level reset: gs_usb will not re-open after 'ip link set down' without
# one. Match VID:PID, not the product string ("USB2CAN V3.3" varies).
for devdir in /sys/bus/usb/devices/*; do
  [ -r "\$devdir/idVendor" ] && [ -r "\$devdir/idProduct" ] || continue
  [ "\$(cat "\$devdir/idVendor")" = "\$VID" ] || continue
  [ "\$(cat "\$devdir/idProduct")" = "\$PID" ] || continue
  [ -w "\$devdir/authorized" ] || continue
  echo "enablecan: resetting USB adapter at \$(basename "\$devdir") (\$VID:\$PID)"
  echo 0 > "\$devdir/authorized"
  sleep 2
  echo 1 > "\$devdir/authorized"
  reset_done=1
done

if [ "\$reset_done" -eq 0 ]; then
  echo "enablecan: no \$VID:\$PID adapter found on the USB bus to reset" >&2
fi

# settle first, then poll: an immediate 'ip link show' can match the dying
# netdev, which then disappears before 'ip link set up'
sleep 3

for _ in \$(seq 20); do
  ip link show "\$IFACE" >/dev/null 2>&1 && break
  sleep 0.5
done

if ! ip link show "\$IFACE" >/dev/null 2>&1; then
  echo "enablecan: \$IFACE did not appear within 10s." >&2
  echo "           Either the USB-CAN adapter is not connected, or" >&2
  echo "           /etc/udev/rules.d/99-can-usb.rules is missing." >&2
  echo "           Present CAN interfaces: \$(ip -brief link show type can 2>/dev/null | awk '{print \$1}' | tr '\n' ' ')" >&2
  echo "           Diagnose with: sudo can-selftest" >&2
  exit 1
fi

# an unwired mttcan comes up UP and ERROR-ACTIVE but carries no data
drv=\$(basename "\$(readlink -f "/sys/class/net/\$IFACE/device/driver" 2>/dev/null)" 2>/dev/null)
if [ "\$drv" = "mttcan" ]; then
  echo "enablecan: WARNING: \$IFACE is an onboard mttcan controller, not the USB" >&2
  echo "           adapter. Unless something is wired to it this bus will be" >&2
  echo "           silent. Check /etc/udev/rules.d/99-can-usb.rules." >&2
elif [ -n "\$drv" ] && [ "\$drv" != "gs_usb" ]; then
  echo "enablecan: note: \$IFACE is driven by '\$drv', not gs_usb."
fi

# gs_usb supports neither CAN-FD nor berr-reporting, and 'ip' rejects the
# whole command if any one option is unsupported. Degrade a step at a time.
configure_and_up() {
  # bitrate cannot be changed while the interface is up
  \$SUDO ip link set down "\$IFACE" 2>/dev/null

  local mode
  if \$SUDO ip link set "\$IFACE" type can bitrate "\$BITRATE" sjw 2 \\
          dbitrate "\$DBITRATE" dsjw 15 berr-reporting on fd on 2>/dev/null; then
    mode="CAN-FD (\$BITRATE/\$DBITRATE)"
  elif \$SUDO ip link set "\$IFACE" type can bitrate "\$BITRATE" sjw 2 berr-reporting on 2>/dev/null; then
    mode="classic CAN (\$BITRATE) with berr-reporting"
  elif \$SUDO ip link set "\$IFACE" type can bitrate "\$BITRATE" sjw 2 2>/dev/null; then
    mode="classic CAN (\$BITRATE), no FD or berr-reporting"
  else
    return 1
  fi

  \$SUDO ip link set up "\$IFACE" 2>/dev/null || return 1
  echo "enablecan: \$IFACE configured as \$mode"
  return 0
}

# retry as a unit; piecemeal retries hide the race above
ok=0
for attempt in 1 2 3; do
  if configure_and_up; then ok=1; break; fi
  echo "enablecan: attempt \$attempt to configure \$IFACE failed; retrying in 2s" >&2
  sleep 2
done

if [ "\$ok" -ne 1 ]; then
  echo "enablecan: failed to configure and bring up \$IFACE after 3 attempts" >&2
  exit 1
fi

# verify, so Restart=on-failure can fire. Checks the LINK only; a bus with
# no other node powered still comes UP and sits in ERROR-PASSIVE. When the
# link is up but carries nothing, 'can-selftest' says whether the adapter or
# the rover is at fault.
for _ in \$(seq 10); do
  if [ "\$(ip -brief link show "\$IFACE" 2>/dev/null | awk '{print \$2}')" = "UP" ]; then
    echo "enablecan: \$IFACE is UP (if no traffic follows, run: sudo can-selftest)"
    exit 0
  fi
  sleep 0.5
done
echo "enablecan: \$IFACE did not come UP" >&2
exit 1
EOF4

    sudo chmod +x /usr/sbin/enablecan

    cat << EOF5 | sudo tee /etc/systemd/system/can.service
[Unit]
Description=Bring up CAN interface
After=network.target
Wants=network.target
# no burst cap, so an adapter plugged in later is still picked up
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/sbin/enablecan
RemainAfterExit=true
TimeoutStartSec=45
Restart=on-failure
# without this systemd retries every ~100ms and storms the journal
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF5

    # can.service is Type=oneshot + RemainAfterExit, so systemd reports it
    # active forever once the link is up and Restart= can never fire again.
    # An adapter knocked loose mid-mission would go unnoticed; poll instead.
    cat << EOF6 | sudo tee /usr/sbin/can-watchdog
#!/bin/bash
# Run from can-watchdog.timer every 30s.
IFACE=$CAN_IFACE

state=\$(ip -brief link show "\$IFACE" 2>/dev/null | awk '{print \$2}')
[ "\$state" = "UP" ] && exit 0

# say whether the adapter is even plugged in
if lsusb 2>/dev/null | grep -qi "$CAN_VID:$CAN_PID"; then
    detail="adapter present on USB"
else
    detail="adapter NOT present on USB, check the cable"
fi

echo "can-watchdog: \$IFACE is \${state:-missing} (\$detail); restarting can.service"
echo "can-watchdog: if this repeats, run: sudo can-selftest"
systemctl restart can.service
EOF6

    sudo chmod +x /usr/sbin/can-watchdog

    cat << EOF7 | sudo tee /etc/systemd/system/can-watchdog.service
[Unit]
Description=Restart can.service if the CAN link has dropped
After=can.service
# not Requires=: this must still run when can.service is failed

[Service]
Type=oneshot
ExecStart=/usr/sbin/can-watchdog
EOF7

    cat << EOF8 | sudo tee /etc/systemd/system/can-watchdog.timer
[Unit]
Description=Periodically verify the CAN link is up

[Timer]
# let can.service try first at boot
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5
Unit=can-watchdog.service

[Install]
WantedBy=timers.target
EOF8

    # A wedged adapter and a powered-down rover look identical from outside:
    # interface UP, ERROR-ACTIVE, zero traffic, driver saying "Did not receive
    # any data from the robot". Loopback mode needs no bus partner, so it tells
    # the two apart.
    cat << EOF9 | sudo tee /usr/sbin/can-selftest
#!/bin/bash
# Is the USB-CAN adapter itself working, or is the bus just quiet?
# Usage: sudo can-selftest
IFACE=$CAN_IFACE
BITRATE=$CAN_BITRATE
VID=$CAN_VID
PID=$CAN_PID

if [ "\$(id -u)" -ne 0 ]; then echo "run me with sudo" >&2; exit 2; fi

if ! lsusb 2>/dev/null | grep -qi "\$VID:\$PID"; then
  echo "RESULT: no \$VID:\$PID adapter on the USB bus."
  echo "        The module is unplugged, or the cable/port is dead."
  exit 1
fi

if ! ip link show "\$IFACE" >/dev/null 2>&1; then
  echo "RESULT: adapter is on USB but there is no '\$IFACE' interface."
  echo "        The udev rename did not run. Check /etc/udev/rules.d/99-can-usb.rules,"
  echo "        then unplug and replug the adapter."
  exit 1
fi

# Remember what to put back.
DRIVER_WAS=\$(systemctl is-active roverrobotics.service 2>/dev/null)
restore() {
  ip link set "\$IFACE" down 2>/dev/null
  ip link set "\$IFACE" type can bitrate "\$BITRATE" loopback off 2>/dev/null
  systemctl restart can.service >/dev/null 2>&1
  [ "\$DRIVER_WAS" = "active" ] && systemctl start roverrobotics.service >/dev/null 2>&1
}
trap restore EXIT

[ "\$DRIVER_WAS" = "active" ] && systemctl stop roverrobotics.service >/dev/null 2>&1
sleep 1

echo "Testing \$IFACE in loopback (no bus partner needed)..."
ip link set "\$IFACE" down 2>/dev/null
if ! ip link set "\$IFACE" type can bitrate "\$BITRATE" loopback on 2>/dev/null; then
  echo "RESULT: could not put \$IFACE into loopback mode."
  exit 1
fi
if ! ip link set "\$IFACE" up 2>/dev/null; then
  echo "RESULT: \$IFACE would not come up even in loopback."
  echo "        The adapter is not responding. Unplug and replug the USB-CAN module."
  exit 1
fi
sleep 1

OUT=\$(mktemp)
timeout 5 candump -n 2 "\$IFACE" > "\$OUT" 2>/dev/null &
DPID=\$!
sleep 1
for i in 1 2 3; do cansend "\$IFACE" 123#DEADBEEF 2>/dev/null; sleep 0.3; done
wait \$DPID 2>/dev/null
GOT=\$(wc -l < "\$OUT" 2>/dev/null)
rm -f "\$OUT"

echo
if [ "\${GOT:-0}" -gt 0 ]; then
  echo "RESULT: ADAPTER IS HEALTHY (looped back \$GOT frame(s))."
  echo "        So a silent bus is NOT the adapter. Check, in this order:"
  echo "          1. the rover is powered on and the e-stop is released"
  echo "          2. the CAN cable between the adapter and the rover"
  echo "          3. 120 ohm termination at both ends of the bus"
  exit 0
else
  echo "RESULT: ADAPTER IS WEDGED. It cannot even receive its own frames."
  echo "        This is the adapter, not the rover and not the wiring."
  echo "        Unplug the USB-CAN module and plug it back in, then:"
  echo "          sudo systemctl restart can.service"
  echo
  echo "        Some boards (notably canable.io CANable) wedge after a warm"
  echo "        reboot and are not recoverable in software: not by usbreset,"
  echo "        driver rebind, module reload, nor by cutting port power."
  echo "        Only a physical replug clears it."
  exit 1
fi
EOF9

    sudo chmod +x /usr/sbin/can-selftest

    sudo systemctl daemon-reload
    sudo systemctl enable can.service
    sudo systemctl enable --now can-watchdog.timer
    sudo systemctl restart can.service
}

try_install_package() {
    local package=$1
    if sudo apt-get install -y "$package" > /dev/null 2>&1; then
        print_green "$package: Success"
        return 0
    else
        print_red "Error encountered while installing $package."
        return 1
    fi
}

install_ros_packages() {
    local error_count=0
    for pkg in "${packages[@]}"; do
        try_install_package "$pkg"
        error_count=$((error_count + $?))
    done

    if [ $error_count -gt 0 ]; then
        echo ""
        print_red "Finished checking/installing packages with $error_count error(s)."
        print_red "Check that ROS2 ($ROS_DISTRO) is installed correctly and repository sources are correct."
        return 1
    else
        echo ""
        print_green "Finished checking/installing packages successfully."
        return 0
    fi
}

[ "$ASSUME_YES" != true ] && clear

#########################################################################
#                          INSTALL PROCESS                              #
#########################################################################

# Robot type selection (TUI/CLI)
select_robot_type

# MAX wheel size selects both the config and the URDF
if [ "$device_type" = "max" ]; then
    select_max_variant
fi

# applies to every robot
select_gamepad

#########################################################################
#              DETECT EXISTING WORKSPACE / ROVER ROS2 REPO              #
#########################################################################
existing_workspace=false
existing_rover_repo=false

if [ -d "$WORKSPACE_DIR" ]; then
    existing_workspace=true
    print_italic "Detected existing workspace at $WORKSPACE_DIR"
    if [ -d "$ROVER_ROS2_DIR" ]; then
        existing_rover_repo=true
        print_italic "Detected existing roverrobotics_ros2 repository in $ROVER_ROS2_DIR"
    fi
    echo ""

    # Ask if they even want to continue when workspace exists
    ask_yes_no "You already have '$WORKSPACE_NAME' created.\nDo you still want to proceed with this installer?" yes continue_install
    if [ "$continue_install" != true ]; then
        echo "Exiting without changes."
        exit 0
    fi
fi

# Decide about installing roverrobotics_ros2 repo
if [ "$existing_workspace" = true ] && [ "$existing_rover_repo" = true ]; then
    # Workspace + rover repo already present
    ask_yes_no "roverrobotics_ros2 already exists in your workspace.\nDo you want to update it from remote?" no install_repo
elif [ "$existing_workspace" = true ] && [ "$existing_rover_repo" = false ]; then
    # Workspace exists but no rover repo
    ask_yes_no "Workspace exists but roverrobotics_ros2 is not present.\nDo you want to clone the Rover Robotics ros2 repository?" yes install_repo
else
    # No workspace yet - original behavior
    ask_yes_no "Would you like to install the Rover Robotics ros2 repository?" yes install_repo
fi

# Component selection (IMU / LIDAR / UDEV / SERVICE)
install_imu=false
install_s2=false
install_udev=true
install_service=false

if [ "$USE_WHIPTAIL" = true ]; then
    CHOICES=$(
        whiptail --title "Rover Components" --checklist "Select components to install (Use Spacebar to select and Press Enter to confirm the choices):" 20 70 8 \
            "IMU"     "BNO055 IMU repository"          OFF \
            "LIDAR"   "RPLIDAR S2 repository"          OFF \
            "UDEV"    "Udev rules"                     ON  \
            "SERVICE" "Automatic start service"        OFF \
            3>&1 1>&2 2>&3
    )

    install_udev=false

    for choice in $CHOICES; do
        case $choice in
            "\"IMU\"")     install_imu=true ;;
            "\"LIDAR\"")   install_s2=true ;;
            "\"UDEV\"")    install_udev=true ;;
            "\"SERVICE\"") install_service=true ;;
        esac
    done
elif [ "$ASSUME_YES" != true ]; then
    # Fallback to CLI yes/no prompts
    ask_yes_no "Would you like to install the BNO055 IMU repository?" no install_imu
    ask_yes_no "Would you like to install the RPLIDAR S2 repository?" no install_s2
    ask_yes_no "Would you like to install the udev rules?" yes install_udev
    ask_yes_no "Would you like to install the automatic start service?" no install_service
fi

# Command-line flags override whatever the menus produced.
[ -n "$ARG_IMU" ]     && install_imu="$ARG_IMU"
[ -n "$ARG_LIDAR" ]   && install_s2="$ARG_LIDAR"
[ -n "$ARG_UDEV" ]    && install_udev="$ARG_UDEV"
[ -n "$ARG_SERVICE" ] && install_service="$ARG_SERVICE"

# defaults from the detected L4T release
if [ -n "$ARG_JP6" ]; then
    use_jp6="$ARG_JP6"
elif [ "$IS_JP6" = true ]; then
    ask_yes_no "Detected JetPack 6 (L4T R${L4T_RELEASE}).\nUse the JetPack 6 gamepad button/axis mapping?\n\nSay yes unless your sticks and triggers come out swapped." yes use_jp6
else
    # Not a JetPack 6 machine, so the stock map is right. No prompt: --jp6 is
    # there if a particular kernel turns out to enumerate the pad differently.
    use_jp6=false
fi

select_realsense

install_number=0
install_total=2
install_can=false

[ "$install_repo" = true ]    && install_total=$((install_total+1))
[ "$install_service" = true ] && install_total=$((install_total+1))
[ "$install_udev" = true ]    && install_total=$((install_total+1))
[ "$install_imu" = true ]     && install_total=$((install_total+1))
[ "$install_s2" = true ]      && install_total=$((install_total+1))
[ "$install_realsense_opt" = true ] && install_total=$((install_total+1))
[ "$install_rs_service" = true ]    && install_total=$((install_total+1))

# Offered even when can.service exists, so a re-run can repair a broken setup
case "$device_type" in
    miti_65|miti|mini|max|mega)
        ask_yes_no "Is the Rover $device_type connected via CAN-TO-USB?\n\nThis (re)installs the udev rule, /usr/sbin/enablecan and can.service." yes rover_can
        if [ "$rover_can" = true ]; then
            install_can=true
            install_total=$((install_total+1))
        fi
        ;;
esac

[ "$ASSUME_YES" != true ] && clear

print_install_settings

# ROS Packages
print_next_install "Checking/Installing dependent packages"
install_ros_packages
echo ""

if [ "$install_repo" = true ]; then
    print_next_install "Installing the Rover Robotics ROS2 packages"

    print_italic "Setting up rover workspace in $WORKSPACE_DIR"
    mkdir -p "$WORKSPACE_DIR/src"

    echo ""
    print_italic "Cloning Rover Robotics ROS2 packages into $WORKSPACE_DIR/src"
    echo ""
    clone_or_update "$ROVER_REPO" "$ROS_DISTRO" "$ROVER_ROS2_DIR"
    echo ""
fi

# Must run before colcon build: launch files and configs are copied into
# install/ at build time. Runs even when the repo was not re-cloned.
if [ -d "$ROVER_ROS2_DIR" ]; then
    print_italic "Configuring the driver for this rover"

    if [ "$install_can" = true ]; then
        patch_device_port
    fi

    if [ "$device_type" = "max" ]; then
        patch_max_launch
    fi

    patch_teleop_gamepad

    if [ "$use_jp6" = true ]; then
        apply_jp6_configs
    else
        restore_stock_configs
    fi
    echo ""
fi

if [ "$install_imu" = true ]; then
    echo ""
    print_next_install "Installing IMU Repository."
    mkdir -p "$WORKSPACE_DIR/src"
    print_italic "Cloning BNO055 packages into $WORKSPACE_DIR/src"
    clone_or_update "$IMU_REPO" "" "$WORKSPACE_DIR/src/bno055"
fi

if [ "$install_s2" = true ]; then
    echo ""
    print_next_install "Installing RPLIDAR_S2 Repository."
    mkdir -p "$WORKSPACE_DIR/src"
    print_italic "Cloning RPLIDAR_S2 packages into $WORKSPACE_DIR/src"
    clone_or_update "$RPLIDAR_REPO" "ros2" "$WORKSPACE_DIR/src/rplidar_ros"
fi

if [ "$install_realsense_opt" = true ]; then
    echo ""
    print_next_install "Installing Intel RealSense support"
    if install_librealsense; then
        install_realsense_ros
    else
        print_yellow "  Skipping the ROS wrapper because the SDK step did not succeed"
    fi
    echo ""
fi

if [ "$install_repo" = true ] || [ "$install_imu" = true ] || [ "$install_s2" = true ] \
   || [ "$install_realsense_opt" = true ]; then
    echo ""
    print_italic "Building Rover workspace packages"
    cd "$WORKSPACE_DIR" || exit 1
    source "/opt/ros/$ROS_DISTRO/setup.bash" > /dev/null
    colcon build
    if [ $? -ne 0 ]; then
        print_red "Failed to build workspace packages"
    else
        print_green "Successfully built packages."
        grep -qF "source $WORKSPACE_DIR/install/setup.bash" ~/.bashrc ||
        echo "source $WORKSPACE_DIR/install/setup.bash" >> ~/.bashrc

        source "$WORKSPACE_DIR/install/setup.bash" > /dev/null
    fi
    echo ""
fi

if [ "$install_can" = true ]; then
    print_next_install "Installing the CAN services"
    print_italic "Setting up CAN for Rover $device_type (interface: $CAN_IFACE)"
    create_can_service > /dev/null 2>&1

    if [ ! -f /etc/systemd/system/can.service ]; then
        print_red "Failed to create can.service @ /etc/systemd/system/can.service"
    else
        print_green "Successfully created can.service"
    fi

    if [ ! -f /usr/sbin/enablecan ]; then
        print_red "Failed to create enablecan @ /usr/sbin/enablecan"
    else
        print_green "Successfully created /usr/sbin/enablecan"
    fi

    if [ ! -f /etc/udev/rules.d/99-can-usb.rules ]; then
        print_red "Failed to install /etc/udev/rules.d/99-can-usb.rules"
    else
        print_green "Successfully installed 99-can-usb.rules ($CAN_IFACE)"
    fi

    if [ "$CAN_MODULE_OK" = true ]; then
        print_green "gs_usb kernel module available"
    elif [ "$IS_TEGRA" = true ]; then
        print_red "gs_usb kernel module is NOT available on this Jetson."
        print_red "The L4T kernel does not ship it, so the USB-CAN adapter will"
        print_red "enumerate as a USB device but never produce a CAN interface."
        print_red "Build it first:"
        print_red "    $SCRIPT_DIR/setup_jetson_can.sh"
    else
        print_red "gs_usb kernel module is NOT available."
        print_red "It normally ships with the stock Ubuntu kernel. Try:"
        print_red "    sudo apt-get install linux-modules-extra-\$(uname -r)"
    fi

    # ifconfig without -a hides down interfaces; ask the kernel directly
    if ip link show "$CAN_IFACE" >/dev/null 2>&1; then
        state=$(ip -brief link show "$CAN_IFACE" | awk '{print $2}')
        if [ "$state" = "UP" ]; then
            print_green "Set up $CAN_IFACE successfully (state: $state)"
        else
            print_yellow "$CAN_IFACE exists but is $state. Check the rover is powered on."
        fi
    else
        print_red "$CAN_IFACE not present. Check the USB-CAN adapter is plugged in and the"
        print_red "rover is powered on, then reboot (the udev rename needs a re-plug)."
    fi
    echo ""
fi

if [ "$install_service" = true ]; then
    print_next_install "Installing the automatic start service"

    print_italic "Creating startup script..."
    create_startup_script "$device_type" > /dev/null
    if [ -f /usr/sbin/roverrobotics ]; then
        print_green "Succeeded in creating the startup script."
    else
        print_red "Failed creating the startup script. File: /usr/sbin/roverrobotics does not exist."
    fi

    echo ""
    print_italic "Creating startup service..."
    create_startup_service > /dev/null 2>&1
    if [ -f /etc/systemd/system/roverrobotics.service ]; then
        print_green "Succeeded in creating the startup service."
    else
        print_red "Failed creating the startup service. File: /etc/systemd/system/roverrobotics.service does not exist."
    fi

    echo ""
fi

if [ "$install_rs_service" = true ]; then
    print_next_install "Installing rover-realsense.service"
    create_realsense_service > /dev/null 2>&1
    if [ -f /etc/systemd/system/rover-realsense.service ]; then
        print_green "Succeeded in creating rover-realsense.service"
    else
        print_red "Failed creating /etc/systemd/system/rover-realsense.service"
    fi
    if [ -f /usr/local/sbin/reset_realsense_usb.sh ]; then
        print_green "Succeeded in creating the RealSense USB reset helper"
    else
        print_red "Failed creating /usr/local/sbin/reset_realsense_usb.sh"
    fi
    echo ""
fi

if [ "$install_udev" = true ]; then
    print_next_install "Installing the udev rules"

    print_italic "Copying Udev rules into /etc/udev/rules.d/55-roverrobotics.rules"
    sudo cp "$BASEDIR/udev/55-roverrobotics.rules" /etc/udev/rules.d/55-roverrobotics.rules
    if [ $? -ne 0 ]; then
        print_red "Failed to copy Udev rules into /etc/udev/rules.d/55-roverrobotics.rules"
    else
        print_green "Successfully copied udev rules"

        echo ""
        print_italic "Reloading udev rules"
        sudo udevadm control --reload-rules > /dev/null
        if [ $? -ne 0 ]; then
            print_red "Failed to reload udev rules"
        else
            print_green "Successfully reloaded rules"
        fi

        echo ""
        print_italic "Triggering udev rules"
        sudo udevadm trigger > /dev/null
        if [ $? -ne 0 ]; then
            print_red "Failed to trigger udevadm"
        else
            print_green "Triggered udev rules. This works most of the time but you may need to restart."
        fi
    fi

    echo ""
fi


# Restarts the services if they exist
if [ -f /etc/systemd/system/roverrobotics.service ] || [ -f /etc/systemd/system/can.service ] \
   || [ -f /etc/systemd/system/rover-realsense.service ]; then
    print_next_install "Restarting services for convenience"
    echo ""
    if [ -f /etc/systemd/system/can.service ]; then
        sudo systemctl restart can.service
        if [ $? -ne 0 ]; then
            print_red "Failed to restart can.service"
        else
            print_green "Restarted can.service"
        fi
    fi
    if [ -f /etc/systemd/system/roverrobotics.service ]; then
        sudo systemctl restart roverrobotics.service
        if [ $? -ne 0 ]; then
            print_red "Failed to restart roverrobotics.service"
        else
            print_green "Restarted roverrobotics.service"
        fi
    fi
    if [ -f /etc/systemd/system/rover-realsense.service ]; then
        sudo systemctl restart rover-realsense.service
        if [ $? -ne 0 ]; then
            print_red "Failed to restart rover-realsense.service"
        else
            print_green "Restarted rover-realsense.service"
        fi
    fi
    echo ""
fi

print_bold "Installation process completed."
echo ""
print_bold "Next steps"
print_bold "----------"
echo "  Open a new terminal (or: source $WORKSPACE_DIR/install/setup.bash)"
echo ""
echo "  Launch the driver manually:"
echo "      ros2 launch roverrobotics_driver ${device_type}_teleop.launch.py"
echo ""
echo "  This rover is configured for a ${gamepad^^} controller."
if [ "$device_type" = "max" ]; then
echo "  MAX wheels: $max_variant (config + URDF set in max.launch.py)."
fi
echo "  To change either, re-run:  ./setup_rover.sh -r $device_type -g <ps4|ps5>"
echo ""
if [ "$install_can" = true ]; then
echo "  Check the CAN bus:"
echo "      ip -details link show $CAN_IFACE      # expect UP and ERROR-ACTIVE"
echo "      candump $CAN_IFACE                    # expect traffic from the VESCs"
echo "      sudo can-selftest                  # if silent: adapter or rover?"
echo ""
fi
if [ "$install_realsense_opt" = true ]; then
echo "  Check the camera:"
echo "      ros2 topic hz /camera/camera/color/image_raw"
echo ""
fi
if [ "$install_rs_service" = true ]; then
echo "  The camera starts automatically at boot:"
echo "      systemctl status rover-realsense.service"
echo ""
fi
if [ "$install_service" = true ]; then
echo "  The driver starts automatically at boot. To check or restart it:"
echo "      systemctl status roverrobotics.service"
echo "      sudo systemctl restart roverrobotics.service"
echo ""
fi
print_yellow "  Reboot recommended, so the udev rules, the gs_usb module and the"
print_yellow "  interface rename all take effect cleanly."
