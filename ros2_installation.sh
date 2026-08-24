#!/usr/bin/env bash
i amset -uo pipefail

#########################################################################
# Script Name   : ROS 2 Installer (Humble / Jazzy)                      #
# Description   : Installs ROS 2 on Ubuntu Jammy (22.04) or Noble       #
#                 (24.04). Idempotent, safe to re-run.                 #
# Author        : Shashank Sharma                                       #
# Email         : shashank@roverrobotics.com                            #
#########################################################################

### ---------- Defaults ----------
DISTRO=""
PACKAGE=""
FORCE=false
DO_UPGRADE=false
REFRESH_KEYS=false

### ---------- Helpers ----------
msg() { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*" >&2; }

usage() {
  cat <<'EOF_USAGE'
ROS 2 installer (Humble / Jazzy) for Ubuntu Jammy / Noble

Usage: ./ros2_installation.sh [options]

With no options the script prompts for the distro and package set.

Options:
  -d, --distro SEL     1 or "humble" | 2 or "jazzy"
  -p, --package SEL    1 or "desktop" | 2 or "base"
  -y, --yes            Non-interactive apt (DEBIAN_FRONTEND=noninteractive)
  -f, --force          Install even if the Ubuntu release does not match
                       the requested ROS 2 distro
      --upgrade        Also run a full 'apt-get upgrade' first. Off by
                       default: on a Jetson this can pull in an L4T or
                       kernel upgrade you did not ask for.
      --refresh-keys   Re-download the ROS keyring even if it is present.
                       Use this if 'apt update' reports a signature error.
  -h, --help           Show this message

Examples:
  ./ros2_installation.sh                    # interactive
  ./ros2_installation.sh -d 1 -p 1 -y       # humble, desktop, unattended
  ./ros2_installation.sh -d jazzy -p base
  ./ros2_installation.sh -d humble -p base --force
EOF_USAGE
}

map_distro() {
  local d="${1,,}"
  case "$d" in
    1|"humble") echo "humble" ;;
    2|"jazzy")  echo "jazzy"  ;;
    *) err "Invalid distro selection: '$1' (use 1=humble, 2=jazzy)"; exit 1 ;;
  esac
}

map_package() {
  local p="${1,,}"
  case "$p" in
    1|"desktop") echo "desktop" ;;
    2|"base"|"ros-base") echo "ros-base" ;;
    *) err "Invalid package selection: '$1' (use 1=desktop, 2=base)"; exit 1 ;;
  esac
}

# One at a time: a single apt-get call under 'set -e' aborted the script
# after ROS was already installed if any one package was missing.
apt_try() {
  local failed=()
  local p
  for p in "$@"; do
    if sudo apt-get install -y "$p" >/dev/null 2>&1; then
      msg "  $p"
    else
      warn "  $p (failed)"
      failed+=("$p")
    fi
  done
  if [ ${#failed[@]} -gt 0 ]; then
    warn "Could not install: ${failed[*]}"
    return 1
  fi
  return 0
}

### ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--distro)     DISTRO="${2:-}"; shift 2 ;;
    -p|--package)    PACKAGE="${2:-}"; shift 2 ;;
    -y|--yes)        export DEBIAN_FRONTEND=noninteractive; shift ;;
    -f|--force)      FORCE=true; shift ;;
    --upgrade)       DO_UPGRADE=true; shift ;;
    --refresh-keys)  REFRESH_KEYS=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

### ---------- Detect OS ----------
# /etc/os-release, not lsb_release. That binary lives in lsb-release, which
# this script installs further down.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
else
  UBUNTU_CODENAME=""
fi

if [[ -z "$UBUNTU_CODENAME" ]]; then
  err "Could not determine the Ubuntu codename from /etc/os-release."
  exit 1
fi

### ---------- Interactive prompts if missing ----------
if [[ -z "$DISTRO" ]]; then
  echo "Choose ROS 2 distro:"
  echo "  [1] Humble (Ubuntu 22.04 jammy)"
  echo "  [2] Jazzy  (Ubuntu 24.04 noble)"
  read -r DISTRO
fi
DISTRO="$(map_distro "$DISTRO")"

if [[ -z "$PACKAGE" ]]; then
  echo "Choose package set:"
  echo "  [1] desktop"
  echo "  [2] base (ros-base)"
  read -r PACKAGE
fi
INSTALL_PACKAGE="$(map_package "$PACKAGE")"

### ---------- OS guard ----------
case "$DISTRO" in
  humble) REQUIRED_OS="jammy" ;;
  jazzy)  REQUIRED_OS="noble" ;;
esac

if [[ "$UBUNTU_CODENAME" != "$REQUIRED_OS" && "$FORCE" != true ]]; then
  warn "=================================================="
  warn "Requested ROS 2 '$DISTRO' expects Ubuntu '$REQUIRED_OS'."
  warn "Detected: '$UBUNTU_CODENAME'. Use --force to continue anyway."
  warn "=================================================="
  exit 1
fi

msg "Proceeding with: ROS 2 '$DISTRO' ($INSTALL_PACKAGE) on Ubuntu '$UBUNTU_CODENAME'"

### ---------- Pre-reqs ----------
sudo apt-get update
sudo apt-get install -y curl gnupg2 lsb-release software-properties-common build-essential locales
sudo add-apt-repository -y universe

### ---------- Locale ----------
# ROS 2 needs UTF-8; on LANG=C colcon and rosdep raise UnicodeDecodeError
if ! locale | grep -qiE 'LANG=.*(UTF-8|utf8)'; then
  msg "Configuring en_US.UTF-8 locale..."
  sudo locale-gen en_US en_US.UTF-8
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
fi

### ---------- Optional full upgrade ----------
if [[ "$DO_UPGRADE" == true ]]; then
  msg "Running full system upgrade (--upgrade)..."
  sudo apt-get update
  sudo apt-get -y upgrade
else
  msg "Skipping full system upgrade (pass --upgrade to enable)."
fi

### ---------- ROS 2 APT repo & key ----------
ROS_KEYRING="/usr/share/keyrings/ros-archive-keyring.gpg"
if [[ ! -f "$ROS_KEYRING" || "$REFRESH_KEYS" == true ]]; then
  msg "Installing ROS keyring..."
  if ! sudo curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o "$ROS_KEYRING"; then
    err "Failed to download the ROS signing key. Check your internet connection."
    exit 1
  fi
fi

ROS_LIST="/etc/apt/sources.list.d/ros2.list"
REPO_LINE="deb [arch=$(dpkg --print-architecture) signed-by=${ROS_KEYRING}] http://packages.ros.org/ros2/ubuntu ${UBUNTU_CODENAME} main"
if [[ ! -f "$ROS_LIST" ]] || ! grep -Fq "$REPO_LINE" "$ROS_LIST"; then
  msg "Configuring ROS APT repository..."
  echo "$REPO_LINE" | sudo tee "$ROS_LIST" >/dev/null
fi

if ! sudo apt-get update; then
  err "'apt-get update' failed."
  err "If the error mentions an expired or invalid signature, re-run with --refresh-keys."
  exit 1
fi

### ---------- Install ROS 2 ----------
PKG_NAME="ros-${DISTRO}-${INSTALL_PACKAGE}"
msg "Installing ${PKG_NAME} ..."
if ! sudo apt-get install -y "${PKG_NAME}"; then
  err "Failed to install ${PKG_NAME}."
  err "Check that '${UBUNTU_CODENAME}' actually has packages for ROS 2 '${DISTRO}'."
  exit 1
fi

# reported individually: a missing package is a warning, not a dead script
msg "Installing development tools..."
apt_try \
  python3-argcomplete \
  python3-colcon-clean \
  python3-colcon-common-extensions \
  python3-rosdep \
  python3-vcstool \
  ros-dev-tools \
  || warn "Some development tools were not installed (see above). ROS 2 itself is fine."

### ---------- rosdep init/update (idempotent) ----------
if [[ ! -e /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  msg "Initializing rosdep..."
  sudo rosdep init || warn "rosdep init failed; you can retry it later."
fi
rosdep update || warn "rosdep update failed; you can retry it later."

### ---------- Shell setup ----------
BASHRC="$HOME/.bashrc"
ROS_SOURCE_LINE="source /opt/ros/${DISTRO}/setup.bash"
COLCON_SOURCE_LINE="source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash"

if ! grep -Fq "$ROS_SOURCE_LINE" "$BASHRC"; then
  echo "$ROS_SOURCE_LINE" >> "$BASHRC"
  msg "Appended to ~/.bashrc: $ROS_SOURCE_LINE"
fi
if [[ -f /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash ]] \
   && ! grep -Fq "$COLCON_SOURCE_LINE" "$BASHRC"; then
  echo "$COLCON_SOURCE_LINE" >> "$BASHRC"
  msg "Appended to ~/.bashrc: $COLCON_SOURCE_LINE"
fi

# Source for current session safely (avoid set -u issues in ROS setup)
set +u
if [[ -f "/opt/ros/${DISTRO}/setup.bash" ]]; then
  # shellcheck disable=SC1090
  source "/opt/ros/${DISTRO}/setup.bash"
fi
set -u

msg "Success! Installed ROS 2 '${DISTRO}' (${INSTALL_PACKAGE})."
echo
echo "ROS 2 '${DISTRO}' (${INSTALL_PACKAGE}) installed on Ubuntu '${UBUNTU_CODENAME}'."
echo "Open a new terminal, or run:  source /opt/ros/${DISTRO}/setup.bash"
echo
echo "Next step, set up your rover:"
echo "    ./setup_rover.sh"
