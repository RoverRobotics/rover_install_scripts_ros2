#!/bin/bash

#########################################################################
# Script Name	: Rover ROS2 Install Script                             #                                                                
# Description	: Sets up ROS2 software for Rover Robots                #                                                                                                                                                      
# Author       	: Jack Rivera                                           #   
# Email         : jack@roverrobotics.com                                #          
#########################################################################

#########################################################################
#                          VARIABLES FOR SETUP                          #
#                          EDIT TO CHANGE REPO                          #
#########################################################################

WORKSPACE_NAME=rover_workspace

# Defined Colors
BOLDRED="\e[1;31m"
ENDCOLOR="\e[0m"
RED="\e[31m"
GREEN="\e[32m"

print_boldred() {
    echo -e "$BOLDRED${1} $ENDCOLOR"
}
print_red() {
    echo -e "$RED${1} $ENDCOLOR"
}
print_green() {
    echo -e "$GREEN${1} $ENDCOLOR"
}

#########################################################################
#                          UNINSTALL PROCESS                            #
#########################################################################

# Prompt the user to confirm uninstall
while true; do
    print_boldred "CAUTION! This script will uninstall all services from Rover Robotics."
    print_boldred "It will not remove the rover_workspace packages. You may do so on your own."
    printf "Are you sure you would like to uninstall? [y/n]: "
    read confirm_uninstall
    case $confirm_uninstall in
        [Yy]* ) confirm_uninstall=true; break;;
        [Nn]* ) confirm_uninstall=false; break;;
        * ) echo "Please answer yes or no.";;
    esac
done

echo ""
if [ "$confirm_uninstall" = true ]; then
    if [ -f /usr/sbin/roverrobotics ]; then
        sudo rm /usr/sbin/roverrobotics
        if [ $? -ne 0 ]; then
            print_red "Unable to remove /usr/sbin/roverrobotics"
        else
            print_green "Successfully removed /usr/sbin/roverrobotics"
        fi
    fi

    if [ -f /etc/systemd/system/roverrobotics.service ]; then
        sudo systemctl stop roverrobotics.service 
        sudo systemctl disable roverrobotics.service
        sudo rm /etc/systemd/system/roverrobotics.service
        sudo systemctl daemon-reload
        if [ $? -ne 0 ]; then
            print_red "Unable to remove /etc/systemd/system/roverrobotics.service"
        else
            print_green "Successfully removed /etc/systemd/system/roverrobotics.service"
        fi
    fi

    if [ -f /usr/sbin/enablecan ]; then
        sudo rm /usr/sbin/enablecan
        if [ $? -ne 0 ]; then
            print_red "Unable to remove /usr/sbin/enablecan"
        else
            print_green "Successfully removed /usr/sbin/enablecan"
        fi
    fi

    if [ -f /etc/systemd/system/rover-realsense.service ]; then
        sudo systemctl stop rover-realsense.service
        sudo systemctl disable rover-realsense.service
        sudo rm -f /etc/systemd/system/rover-realsense.service \
                   /usr/local/sbin/reset_realsense_usb.sh \
                   /etc/sudoers.d/rover-realsense
        sudo systemctl daemon-reload
        print_green "Successfully removed rover-realsense.service and its reset helper"
    fi

    if [ -f /etc/systemd/system/can-watchdog.timer ]; then
        sudo systemctl stop can-watchdog.timer
        sudo systemctl disable can-watchdog.timer
        sudo rm -f /etc/systemd/system/can-watchdog.timer \
                   /etc/systemd/system/can-watchdog.service \
                   /usr/sbin/can-watchdog \
                   /usr/sbin/can-selftest
        sudo systemctl daemon-reload
        print_green "Successfully removed can-watchdog timer, service and script"
    fi

    if [ -f /etc/systemd/system/can.service ]; then
        sudo systemctl stop can.service 
        sudo systemctl disable can.service
        sudo rm /etc/systemd/system/can.service
        sudo systemctl daemon-reload
        if [ $? -ne 0 ]; then
            print_red "Unable to remove /etc/systemd/system/can.service"
        else
            print_green "Successfully removed /etc/systemd/system/can.service"
        fi
    fi

    if [ -f /etc/modules-load.d/gs_usb.conf ]; then
        sudo rm /etc/modules-load.d/gs_usb.conf
        if [ $? -ne 0 ]; then
            print_red "Unable to remove /etc/modules-load.d/gs_usb.conf"
        else
            print_green "Successfully removed /etc/modules-load.d/gs_usb.conf"
        fi
    fi

    for rule in 55-roverrobotics.rules 99-can-usb.rules; do
        if [ -f "/etc/udev/rules.d/$rule" ]; then
            sudo rm "/etc/udev/rules.d/$rule"
            if [ $? -ne 0 ]; then
                print_red "Unable to remove /etc/udev/rules.d/$rule"
            else
                print_green "Successfully removed /etc/udev/rules.d/$rule"
            fi
            reload_udev=true
        fi
    done

    if [ "${reload_udev:-false}" = true ]; then
        sudo udevadm control --reload-rules > /dev/null
        if [ $? -ne 0 ]; then
            print_red "Failed to reload udev rules"
        else
            print_green "Successfully reloaded rules"
        fi
        sudo udevadm trigger > /dev/null
        if [ $? -ne 0 ]; then
            print_red "Failed to trigger udevadm"
        else
            print_green "Triggered udev rules. This works most of the time but you may need to restart."
        fi
    fi

    # absolute path now, ~ path in older versions
    for line in "source ~/$WORKSPACE_NAME/install/setup.bash" \
                "source $HOME/$WORKSPACE_NAME/install/setup.bash"; do
        if grep -qF "$line" ~/.bashrc; then
            sed -i "\|$line|d" ~/.bashrc
            print_green "Removed from ~/.bashrc: $line"
        fi
    done
fi

