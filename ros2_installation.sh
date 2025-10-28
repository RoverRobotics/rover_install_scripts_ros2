#!/usr/bin/env bash
set -euo pipefail

# ROS 2 installer (Humble/Jazzy) for Ubuntu Jammy/Noble
# - Choose distro/package via 1/2 menus (or flags)
# - Verifies supported Ubuntu release (use --force to skip)
# - Idempotent: safe to re-run
#
# Usage examples:
#   ./install_ros2.sh                 # interactive 1/2 prompts
#   ./install_ros2.sh -d 1 -p 1 -y    # non-interactive (1=humble, 1=desktop)
#   ./install_ros2.sh -d jazzy -p 2   # non-interactive (2=base)
#   ./install_ros2.sh -d jazzy -p desktop --force

### ---------- Defaults ----------
DISTRO=""
PACKAGE=""
FORCE=false

### ---------- Helpers ----------
msg() { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*" >&2; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

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

### ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--distro)   DISTRO="${2:-}"; shift 2 ;;
    -p|--package)  PACKAGE="${2:-}"; shift 2 ;;
    -y|--yes)      export DEBIAN_FRONTEND=noninteractive; shift ;;
    -f|--force)    FORCE=true; shift ;;
    -h|--help)
      sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

### ---------- Detect OS ----------
need_cmd lsb_release
UBUNTU_CODENAME="$(lsb_release -sc || true)"
if [[ -z "$UBUNTU_CODENAME" ]]; then
  err "Could not determine Ubuntu codename."
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
sudo apt-get install -y curl gnupg2 lsb-release software-properties-common build-essential
sudo add-apt-repository -y universe

# General system updates (systemd/udev etc. per ROS docs)
sudo apt-get update
sudo apt-get -y upgrade

### ---------- ROS 2 APT repo & key ----------
ROS_KEYRING="/usr/share/keyrings/ros-archive-keyring.gpg"
if [[ ! -f "$ROS_KEYRING" ]]; then
  msg "Installing ROS keyring..."
  sudo curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o "$ROS_KEYRING"
fi

ROS_LIST="/etc/apt/sources.list.d/ros2.list"
REPO_LINE="deb [arch=$(dpkg --print-architecture) signed-by=${ROS_KEYRING}] http://packages.ros.org/ros2/ubuntu ${UBUNTU_CODENAME} main"
if [[ ! -f "$ROS_LIST" ]] || ! grep -Fq "$REPO_LINE" "$ROS_LIST"; then
  msg "Configuring ROS APT repository..."
  echo "$REPO_LINE" | sudo tee "$ROS_LIST" >/dev/null
fi

sudo apt-get update

### ---------- Install ROS 2 ----------
PKG_NAME="ros-${DISTRO}-${INSTALL_PACKAGE}"
msg "Installing ${PKG_NAME} ..."
sudo apt-get install -y "${PKG_NAME}"

# Useful dev tooling
sudo apt-get install -y \
  python3-argcomplete \
  python3-colcon-clean \
  python3-colcon-common-extensions \
  python3-rosdep \
  python3-vcstool \
  ros-dev-tools

### ---------- rosdep init/update (idempotent) ----------
if [[ ! -e /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  msg "Initializing rosdep..."
  sudo rosdep init
fi
rosdep update

### ---------- Shell setup ----------
BASHRC="$HOME/.bashrc"
ROS_SOURCE_LINE="source /opt/ros/${DISTRO}/setup.bash"
COLCON_SOURCE_LINE="source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash"

if ! grep -Fq "$ROS_SOURCE_LINE" "$BASHRC"; then
  echo "$ROS_SOURCE_LINE" >> "$BASHRC"
  msg "Appended to ~/.bashrc: $ROS_SOURCE_LINE"
fi
if ! grep -Fq "$COLCON_SOURCE_LINE" "$BASHRC"; then
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
echo "✅ ROS 2 '${DISTRO}' (${INSTALL_PACKAGE}) installed on Ubuntu '${UBUNTU_CODENAME}'."
echo "👉 Open a new terminal or run:  source /opt/ros/${DISTRO}/setup.bash"
