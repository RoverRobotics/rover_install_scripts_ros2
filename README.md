# 🚀 Rover Robotics ROS 2 Installation Scripts

Easily set up your Rover Robotics platform with ROS 2 using these install scripts.  
These scripts handle everything, from installing ROS 2 to configuring your robot, udev rules, and system services, so you can get rolling quickly!

---

## 🧠 Before You Begin

✅ **Operating System:** Ubuntu 22.04 (Jammy) or Ubuntu 24.04 (Noble)  
✅ **ROS 2 Versions Supported:** Humble / Jazzy  
✅ **Internet Connection:** Required for installation  
✅ **Recommended Hardware:** Jetson AGX Orin, Jetson Orin Nano, NUCs, Raspberry PIs, or similar Linux computer  

---

## ⚙️ Step 1 – Install ROS 2 (if not already installed)

If ROS 2 isn’t installed yet, you can use our simple setup script:

```bash
git clone https://github.com/RoverRobotics/rover_install_scripts_ros2
cd rover_install_scripts_ros2
sudo chmod +x ros2_installation.sh
./ros2_installation.sh
```

👉 The script will ask which ROS 2 distribution you want (Humble or Jazzy) and whether you want the **Desktop** or **Base** installation.

Once complete, ROS 2 will be ready to use on your system!

---

## 🤖 Step 2 – Set Up Your Rover

Next, run the main setup script to configure your Rover robot:

```bash
cd rover_install_scripts_ros2
sudo chmod +x setup_rover.sh
./setup_rover.sh
```

The installer will guide you through a few setup options:

- **Select your Rover model** (Mini, Miti, Pro, Zero, Max, or Mega)  
- **Set up udev rules** for automatic device detection  
- **Optionally create a system service** (`roverrobotics.service`) that automatically starts your Rover driver when the computer boots up

If you prefer to start the driver manually, simply **decline** the service creation when prompted.

---

## 🔌 Connecting Your Rover

Most M-Seried rovers (mini, miti, max, and mega) use a **CAN-to-USB converter**, which this script automatically configures.

---

## ✅ All Set!

Once installation finishes successfully, your Rover is ready to run!  
Power up your system, and if you enabled the service, the Rover driver will start automatically on boot.

You can now use your ROS 2 workspace to teleoperate, navigate, or develop custom applications for your Rover Robotics platform.

---

## 🧩 Need Help?

For troubleshooting or questions, please check the [Rover Robotics documentation](https://roverrobotics.com) or reach out to the community on the [Rover Robotics GitHub Discussions](https://github.com/RoverRobotics).

---

### 💡 Pro Tip:
If you modify configuration files or update the driver, you can restart the service without rebooting using:

```bash
sudo systemctl restart roverrobotics.service
```
