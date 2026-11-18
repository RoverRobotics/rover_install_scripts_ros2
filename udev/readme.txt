# Install these udev rules with
# sudo cp 55-roverrobotics.rules /etc/udev/rules.d/55-roverrobotics.rules && sudo cp 70-rover-gamepad.rules /etc/udev/rules.d/70-rover-gamepad.rules && sudo udevadm control --reload-rules && sudo udevadm trigger
#
# 70-rover-gamepad.rules is separate on purpose: it matches ID_INPUT_JOYSTICK,
# which udev only sets at 60-input-id.rules, so it cannot live in a 55- file.
