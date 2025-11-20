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
WORKSPACE_NAME=rover_workspace
CURRENT_DIR=${PWD}
BASEDIR=$CURRENT_DIR
WORKSPACE_DIR="$HOME/$WORKSPACE_NAME"
ROVER_ROS2_DIR="$WORKSPACE_DIR/src/roverrobotics_ros2"

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

echo "Using ROS 2 distribution: $ROS_DISTRO"
echo ""

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
)

#########################################################################
#                          HELPER FUNCTIONS                             #
#########################################################################
RED="\e[31m"
GREEN="\e[32m"
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

print_install_settings() {
    print_bold "====================================="
    print_boldblue "                                     "
    print_bold "Installation settings:               "
    print_bold "----------------------------         "
    print_boldblue "Robot type:    $device_type          "
    print_boldblue "ROS 2 Distro:  $ROS_DISTRO           "
    print_boldblue "Workspace:     $WORKSPACE_DIR        "
    print_boldblue "Repo install:  $install_repo         "
    print_boldblue "Service:       $install_service      "
    print_boldblue "Udev:          $install_udev         "
    print_boldblue "CPU (x86-NV):  $cpu_type             "
    print_boldblue "BNO055 IMU:    $install_imu          "
    print_boldblue "RPLidar S2:    $install_s2           "
    print_boldblue "                                     "
    print_bold "====================================="
    echo ""
}

# UI helper: use whiptail if available, otherwise fall back to plain read
if command -v whiptail >/dev/null 2>&1; then
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

    if [ "$USE_WHIPTAIL" = true ]; then
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

# Define the install service functions
create_startup_script() {
    local robot_type=$1
    cat << EOF2 | sudo tee /usr/sbin/roverrobotics
#!/bin/bash
source ~/rover_workspace/install/setup.bash
ros2 launch roverrobotics_driver ${robot_type}_teleop.launch.py
PID=\$!
wait "\$PID"
EOF2

    sudo chmod +x /usr/sbin/roverrobotics
}

create_startup_service() {
    cat << EOF3 | sudo tee /etc/systemd/system/roverrobotics.service
[Service]
Type=simple
User=$USER
ExecStart=/bin/bash /usr/sbin/roverrobotics
[Install]
WantedBy=multi-user.target
EOF3

    sudo systemctl enable roverrobotics.service
}

create_can_service() {      
    cat << EOF4 | sudo tee /usr/sbin/enablecan
#!/bin/bash
sudo ip link set can0 type can bitrate 500000 sjw 2 dbitrate 2000000 dsjw 15 berr-reporting on fd on
sudo ip link set up can0
EOF4

    sudo chmod +x /usr/sbin/enablecan

    cat << EOF5 | sudo tee /etc/systemd/system/can.service
[Service]
Type=simple
User=root
ExecStart=/usr/sbin/enablecan
[Install]
WantedBy=multi-user.target
EOF5

    sudo systemctl enable can.service

    sudo ip link set can0 type can bitrate 500000 sjw 2 dbitrate 2000000 dsjw 15 berr-reporting on fd on
    sudo ip link set up can0
}


try_install_package() {
    local package=$1
    sudo apt-get install -y $package > /dev/null
    if [ $? -ne 0 ]; then
        print_red "Error encountered while installing $package."
        return 1
    else
        print_green "$package: Success"
        return 0
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

clear

#########################################################################
#                          INSTALL PROCESS                              #
#########################################################################

# Robot type selection (TUI/CLI)
select_robot_type

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
    ask_yes_no "roverrobotics_ros2 already exists in your workspace.\nDo you want to re-clone/update it from remote?" no install_repo
elif [ "$existing_workspace" = true ] && [ "$existing_rover_repo" = false ]; then
    # Workspace exists but no rover repo
    ask_yes_no "Workspace exists but roverrobotics_ros2 is not present.\nDo you want to clone the Rover Robotics ros2 repository?" yes install_repo
else
    # No workspace yet – original behavior
    ask_yes_no "Would you like to install the Rover Robotics ros2 repository?" yes install_repo
fi

# Component selection (IMU / LIDAR / UDEV / SERVICE)
if [ "$USE_WHIPTAIL" = true ]; then
    CHOICES=$(
        whiptail --title "Rover Components" --checklist "Select components to install (Use Spacebar to select and Press Enter to confirm the choices):" 20 70 8 \
            "IMU"     "BNO055 IMU repository"          OFF \
            "LIDAR"   "RPLIDAR S2 repository"          OFF \
            "UDEV"    "Udev rules"                     ON  \
            "SERVICE" "Automatic start service"        OFF \
            3>&1 1>&2 2>&3
    )

    install_imu=false
    install_s2=false
    install_udev=false
    install_service=false

    for choice in $CHOICES; do
        case $choice in
            "\"IMU\"")     install_imu=true ;;
            "\"LIDAR\"")   install_s2=true ;;
            "\"UDEV\"")    install_udev=true ;;
            "\"SERVICE\"") install_service=true ;;
        esac
    done
else
    # Fallback to CLI yes/no prompts
    ask_yes_no "Would you like to install the BNO055 IMU repository?" no install_imu
    ask_yes_no "Would you like to install the RPLIDAR S2 repository?" no install_s2
    ask_yes_no "Would you like to install the udev rules?" yes install_udev
    ask_yes_no "Would you like to install the automatic start service?" no install_service
fi

# CPU type (x86-based NVIDIA?)
ask_yes_no "Are you using x86-based NVIDIA computer?" no cpu_type

install_number=0
install_total=2
install_can=false

if [ "$install_repo" = true ]; then
    install_total=$((install_total+1))
fi

if [ "$install_service" = true ]; then
    install_total=$((install_total+1))
fi

if [ "$install_udev" = true ]; then
    install_total=$((install_total+1))
fi

if [ "$install_imu" = true ]; then
    install_total=$((install_total+1))
fi

if [ "$install_s2" = true ]; then
    install_total=$((install_total+1))
fi

if [ "$device_type" = "miti_65" ] || [ "$device_type" = "miti" ] || [ "$device_type" = "mini" ] || [ "$device_type" = "max" ] || [ "$device_type" = "mega" ]; then
    if [ ! -f /etc/systemd/system/can.service ]; then
        install_can=true
    fi
fi

# Prompt the user to decide about installing CAN driver
if [ "$install_can" = true ]; then
    ask_yes_no "Is the Rover $device_type connected via CAN-TO-USB?" yes rover_can
    if [ "$rover_can" = true ]; then
        install_can=true
        install_total=$((install_total+1))
    else
        install_can=false
    fi
fi

clear

print_install_settings

# ROS Packages
print_next_install "Checking/Installing dependent packages"
install_ros_packages
echo ""

if [ "$install_repo" = true ]; then
    print_next_install "Installing the Rover Robotics ROS2 packages"
    
    print_italic "Setting up rover workspace in $WORKSPACE_DIR"
    mkdir -p "$WORKSPACE_DIR/src" > /dev/null
    cd "$WORKSPACE_DIR/src" > /dev/null

    echo ""
    print_italic "Cloning Rover Robotics ROS2 packages into $WORKSPACE_DIR/src"
    echo ""
    git clone "$ROVER_REPO" -b "$ROS_DISTRO" > /dev/null
    if [ $? -ne 0 ]; then
        print_red "Failed to clone Rover Robotics ROS2 packages (branch: $ROS_DISTRO)"
    else
        print_green "Successfully cloned packages."
    fi

    echo ""

    if [ "$cpu_type" = true ]; then
        print_italic "You selected x86-based NVIDIA."
        echo ""
        cd "$WORKSPACE_DIR/src/roverrobotics_ros2/roverrobotics_driver/config" > /dev/null

        # Delete "ps4_controller_config.yaml" if it exists
        if [ -f "ps4_controller_config.yaml" ]; then
            rm "ps4_controller_config.yaml"
            echo "Deleted ps4_controller_config.yaml"
        fi
        # Rename "ps4_controller_config_jp6.yaml" to "ps4_controller_config.yaml" if it exists
        if [ -f "ps4_controller_config_jp6.yaml" ]; then
            mv "ps4_controller_config_jp6.yaml" "ps4_controller_config.yaml"
            echo "Renamed ps4_controller_config_jp6.yaml to ps4_controller_config.yaml"
        else
            echo "ps4_controller_config_jp6 not found."
        fi

    else
        print_italic "You selected non-x86 NVIDIA (e.g., Jetson or other)."
    fi
fi
    
if [ "$install_imu" = true ]; then
    echo ""
    print_next_install "Installing IMU Repository."
    mkdir -p "$WORKSPACE_DIR/src" > /dev/null
    cd "$WORKSPACE_DIR/src" > /dev/null
    echo ""
    print_italic "Cloning BNO055 packages into $WORKSPACE_DIR/src"
    echo ""
    git clone "$IMU_REPO" > /dev/null
    if [ $? -ne 0 ]; then
        print_red "Failed to clone BNO055 packages"
    else
        print_green "Successfully cloned BNO055 packages."
    fi
fi

if [ "$install_s2" = true ]; then
    echo ""
    print_next_install "Installing RPLIDAR_S2 Repository."
    mkdir -p "$WORKSPACE_DIR/src" > /dev/null
    cd "$WORKSPACE_DIR/src" > /dev/null
    echo ""
    print_italic "Cloning RPLIDAR_S2 packages into $WORKSPACE_DIR/src"
    echo ""
    git clone -b ros2 "$RPLIDAR_REPO" > /dev/null
    if [ $? -ne 0 ]; then
        print_red "Failed to clone RPLIDAR_S2 packages"
    else
        print_green "Successfully cloned RPLIDAR_S2 packages."
    fi
fi

if [ "$install_repo" = true ] || [ "$install_imu" = true ] || [ "$install_s2" = true ]; then
    echo ""
    print_italic "Building Rover workspace packages"
    cd "$WORKSPACE_DIR" > /dev/null
    source "/opt/ros/$ROS_DISTRO/setup.bash" > /dev/null
    colcon build
    if [ $? -ne 0 ]; then
        print_red "Failed to build workspace packages"
    else
        print_green "Successfully built packages."
        grep -F "source ~/$WORKSPACE_NAME/install/setup.bash" ~/.bashrc ||
        echo "source ~/$WORKSPACE_NAME/install/setup.bash" >> ~/.bashrc

        source "$HOME/$WORKSPACE_NAME/install/setup.bash" > /dev/null
    fi
    echo ""
fi

if [ "$install_can" = true ]; then
    print_next_install "Installing the CAN services"
    print_italic "Setting up CAN for Rover $device_type"
    create_can_service > /dev/null

    if [ ! -f /etc/systemd/system/can.service ]; then
        print_red "Failed to create can.service @ /etc/systemd/system/can.service"
    else
        print_green "Successfully created can.service"
    fi

    if [ ! -f /usr/sbin/enablecan ]; then
        print_red "Failed to create enablecan @ /usr/sbin/enablecan"
    else
        print_green "Successfully created enablecan.sh"
    fi

    if ifconfig | grep -q can0; then
        print_green "Set up can0 successfully"
    else
        print_red "Failed to setup can0 device. Check computer is connected to robot and robot is powered on."
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
    create_startup_service > /dev/null
    if [ -f /etc/systemd/system/roverrobotics.service ]; then
        print_green "Succeeded in creating the startup service."
    else
        print_red "Failed creating the startup service. File: /etc/systemd/system/roverrobotics.service does not exist."
    fi

    echo ""
fi

if [ "$install_udev" = true ]; then
    print_next_install "Installing the udev rules"
    
    print_italic "Copying Udev rules into /etc/udev/rules.d/55-roverrobotics.rules"
    sudo cp "$BASEDIR/udev/55-roverrobotics.rules" /etc/udev/rules.d/55-roverrobotics.rules > /dev/null
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
if [ -f /etc/systemd/system/roverrobotics.service ] || [ -f /etc/systemd/system/can.service ]; then
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
    echo ""
fi
print_bold "Installation process completed."