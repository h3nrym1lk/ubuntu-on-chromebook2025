#!/bin/bash
#
# Script to install Ubuntu Server on Chromebooks (ARM)
# - Adapted from ChrUbuntu script
#
# EXAMPLES:
#   sudo bash install-ubuntu-server.sh
#   sudo bash install-ubuntu-server.sh /dev/mmcblk0  # Specify target disk explicitly
# Exit immediately if a command exits with a non-zero status.
set -e

# --- ChromeOS Checks ---
fw_type="`crossystem mainfw_type`"
if [ ! "$fw_type" = "developer" ]
then
    echo -e "
You're Chromebook is not running a developer BIOS!"
    echo -e "You need to run:"
    echo -e ""
    echo -e "sudo chromeos-firmwareupdate --mode=todev"
    echo -e ""
    echo -e "and then re-run this script."
    exit 1
fi

powerd_status="`initctl status powerd`"
if [ ! "$powerd_status" = "powerd stop/waiting" ]
then
  echo -e "Stopping powerd to keep display from timing out..."
  initctl stop powerd
fi
setterm -blank 0

# --- Disk and Partitioning ---
if [ "$1" != "" ]; then
  target_disk=$1 # Allow specifying disk as first argument
  echo "Got ${target_disk} as target drive"
  echo ""
  echo "WARNING! All data on this device will be wiped out! Continue at your own risk!"
  echo ""
  read -p "Press [Enter] to install Ubuntu Server on ${target_disk} or CTRL+C to quit"
  ext_size="`blockdev --getsz ${target_disk}`"
  aroot_size=$((ext_size - 65600 - 33)) # Leave space for KERN-A
  echo "Creating new partition table..."
  cgpt create ${target_disk}
  cgpt add -i 6 -b 64 -s 32768 -S 1 -P 5 -l KERN-A -t "kernel" ${target_disk} # KERN-A
  cgpt add -i 7 -b 65600 -s $aroot_size -l ROOT-A -t "rootfs" ${target_disk} # ROOT-A
  sync
  # --- FIX: Add retry for blockdev --rereadpt ---
  echo "Re-reading partition table..."
  for i in {1..5}; do
      if blockdev --rereadpt ${target_disk}; then
          echo "Partition table re-read successfully (attempt $i)."
          break
      else
          echo "blockdev --rereadpt failed (attempt $i). Retrying in 1 second..."
          sleep 1
      fi
  done
  # partx might also fail if the device is busy, ignore errors for now
  partx -a ${target_disk} 2>/dev/null || echo "Warning: partx failed, might need manual intervention."
  # --- End Fix ---
  crossystem dev_boot_usb=1
  # No reboot needed for fresh disk, proceed
else
  target_disk="`rootdev -d -s`"
  # Check if KERN-C (6) and ROOT-C (7) are already sized for use
  ckern_size="`cgpt show -i 6 -n -s -q ${target_disk}`"
  croot_size="`cgpt show -i 7 -n -s -q ${target_disk}`"
  state_size="`cgpt show -i 1 -n -s -q ${target_disk}`"

  # If KERN-C and ROOT-C are minimal (likely 1 sector), we need to partition
  if [ "$ckern_size" =  "1" -o "$croot_size" = "1" ]
  then
    max_ubuntu_size=$(($state_size/1024/1024/2)) # In GB
    rec_ubuntu_size=$(($max_ubuntu_size - 1))
    while :
    do
      read -p "Enter the size in gigabytes you want to reserve for Ubuntu Server. Acceptable range is 5 to $max_ubuntu_size, recommended max is $rec_ubuntu_size: " ubuntu_size
      # --- FIXED: Line 209 equivalent - Robust integer check ---
      if ! [[ "$ubuntu_size" =~ ^[0-9]+$ ]]; then
        echo -e "
Numbers only please...
"
        continue
      fi
      if [ $ubuntu_size -lt 5 -o $ubuntu_size -gt $max_ubuntu_size ]
      then
        echo -e "
That number is out of range. Enter a number 5 through $max_ubuntu_size
"
        continue
      fi
      break
    done

    # Calculate sizes in sectors
    rootc_size=$(($ubuntu_size*1024*1024*2))
    kernc_size=32768 # 16MB for kernel
    stateful_size=$(($state_size - $rootc_size - $kernc_size))

    stateful_start="`cgpt show -i 1 -n -b -q ${target_disk}`"
    kernc_start=$(($stateful_start + $stateful_size))
    rootc_start=$(($kernc_start + $kernc_size))

    echo -e "
Modifying partition table to make room for Ubuntu Server."
    echo -e "Your Chromebook will reboot, wipe the ROOT-C/KERN-C partitions, and then"
    echo -e "you should re-run this script..."
    # --- FIX: Ensure stateful is unmounted before repartitioning ---
    echo "Attempting to unmount /mnt/stateful_partition..."
    # Loop a few times to ensure it's unmounted, as processes might quickly remount it
    for i in {1..5}; do
        if umount /mnt/stateful_partition 2>/dev/null; then
            echo "Successfully unmounted /mnt/stateful_partition (attempt $i)."
            break
        else
            echo "Unmount attempt $i failed or already unmounted. Retrying in 1 second..."
            sleep 1
        fi
    done
    # Final check
    if mount | grep -q '/mnt/stateful_partition'; then
        echo "Error: Failed to unmount /mnt/stateful_partition. Cannot proceed safely."
        echo "Please ensure no processes are using it and try again."
        exit 1
    else
        echo "/mnt/stateful_partition is confirmed unmounted."
    fi
    # --- End Fix ---
    # stateful first
    cgpt add -i 1 -b $stateful_start -s $stateful_size -l STATE ${target_disk} # Resize STATE
    # now kernc
    cgpt add -i 6 -b $kernc_start -s $kernc_size -l KERN-C ${target_disk}    # KERN-C
    # finally rootc
    cgpt add -i 7 -b $rootc_start -s $rootc_size -l ROOT-C ${target_disk}    # ROOT-C
    sync
    # --- FIX: Add retry for blockdev --rereadpt after modification ---
    echo "Re-reading partition table after modification..."
    for i in {1..5}; do
        if blockdev --rereadpt ${target_disk}; then
            echo "Partition table re-read successfully (attempt $i)."
            break
        else
            echo "blockdev --rereadpt failed (attempt $i). Retrying in 1 second..."
            sleep 1
        fi
    done
    # --- End Fix ---
    reboot
    exit 0 # Exit after reboot trigger
  fi
  # If partitions exist and are large enough, we'll use them (fall through)
fi

# --- Determine Target Partitions ---
if [[ "${target_disk}" =~ "mmcblk" ]]
then
  target_rootfs="${target_disk}p7"
  target_kern="${target_disk}p6"
else
  target_rootfs="${target_disk}7"
  target_kern="${target_disk}6"
fi

echo "Target Kernel Partition: $target_kern"
echo "Target Root FS Partition: ${target_rootfs}"

# Check if already mounted
if mount | grep -q ${target_rootfs}; then
  echo "Refusing to continue since ${target_rootfs} appears to be mounted. Try rebooting or unmounting it first."
  exit 1
fi

# --- Format Root Filesystem ---
echo "Formatting ${target_rootfs} as ext4..."
mkfs.ext4 -F ${target_rootfs} # -F to force if needed

# --- Create Mount Point ---
if [ ! -d /tmp/urfs ]; then
  mkdir /tmp/urfs
fi

# --- Mount Root Filesystem ---
echo "Mounting ${target_rootfs} to /tmp/urfs..."
mount -t ext4 ${target_rootfs} /tmp/urfs

# --- Determine Architecture and Set Ubuntu Details ---
chromebook_arch="`uname -m`"
ubuntu_metapackage="ubuntu-server" # Default for server
ubuntu_version="22.04"             # Hardcoded LTS version

if [ "$chromebook_arch" = "x86_64" ]
then
  ubuntu_arch="amd64"
elif [ "$chromebook_arch" = "i686" ]
then
  ubuntu_arch="i386"
elif [ "$chromebook_arch" = "armv7l" ]
then
  ubuntu_arch="armhf"
  # XE303CE is ARM, server is appropriate default
  ubuntu_metapackage="ubuntu-server"
else
  echo -e "Error: This script doesn't know how to install Ubuntu Server on $chromebook_arch"
  exit 1
fi

echo -e "
Chrome device architecture is: $chromebook_arch
"
echo -e "Installing Ubuntu ${ubuntu_version} ($ubuntu_metapackage)
"
echo -e "Installing Ubuntu Arch: $ubuntu_arch
"
read -p "Press [Enter] to continue..."

# --- Download and Extract Ubuntu Base ---
tar_file="http://cdimage.ubuntu.com/ubuntu-base/releases/$ubuntu_version/release/ubuntu-base-$ubuntu_version-base-$ubuntu_arch.tar.gz"

# Use a temporary directory for download
if [ ! -d /tmp/ubuntu_dl ]; then
  mkdir /tmp/ubuntu_dl
fi

echo "Downloading Ubuntu Base ${ubuntu_version} for ${ubuntu_arch}..."
# --- FIXED: Line 214 equivalent - Use 'curl' instead of 'wget' ---
curl -L $tar_file -o /tmp/ubuntu_dl/ubuntu-base.tar.gz

# Verify it's a valid gzip file before extraction
if ! gzip -t /tmp/ubuntu_dl/ubuntu-base.tar.gz 2>/dev/null; then
    echo "Error: Downloaded file is not a valid gzip archive. It might be an HTML error page."
    echo "Please check the URL: $tar_file"
    ls -l /tmp/ubuntu_dl/ubuntu-base.tar.gz
    file /tmp/ubuntu_dl/ubuntu-base.tar.gz
    umount /tmp/urfs 2>/dev/null || true
    exit 1
fi

echo "Extracting Ubuntu Base..."
tar xzvvp -C /tmp/urfs/ -f /tmp/ubuntu_dl/ubuntu-base.tar.gz

# Clean up download
rm -f /tmp/ubuntu_dl/ubuntu-base.tar.gz

# --- Basic Filesystem Setup ---
echo "Setting up basic filesystem structure..."

# Mount necessary filesystems for chroot
mount -o bind /proc /tmp/urfs/proc
mount -o bind /dev /tmp/urfs/dev
mount -o bind /dev/pts /tmp/urfs/dev/pts
mount -o bind /sys /tmp/urfs/sys

# Copy resolver config for chroot internet access
cp /etc/resolv.conf /tmp/urfs/etc/

# Basic hostname
echo "ubuntu-server" > /tmp/urfs/etc/hostname

# Basic hosts file
cat > /tmp/urfs/etc/hosts << EOF
127.0.0.1   localhost ubuntu-server
::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Copy cgpt for use inside the new system
if [ -f /usr/bin/old_bins/cgpt ]; then
  mkdir -p /tmp/urfs/usr/bin/
  cp /usr/bin/old_bins/cgpt /tmp/urfs/usr/bin/
else
  cp /usr/bin/cgpt /tmp/urfs/usr/bin/
fi
chmod a+rx /tmp/urfs/usr/bin/cgpt

# --- Create Installation Script for Chroot ---
# This script will run inside the new Ubuntu environment
cat > /tmp/urfs/install-ubuntu-server.sh << 'EOF_SCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Update package list
apt-get update

# Install essential packages including server meta-package
apt-get -y install ubuntu-minimal
apt-get -y install ubuntu-server # This pulls in server essentials

# Install SSH server for remote access
apt-get -y install openssh-server

# Create a default user (change 'serveruser' and password as needed)
# Use a strong password or set up SSH keys later
USERNAME="serveruser"
USERPASS="serverpassword" # <--- CHANGE THIS PASSWORD !!!

useradd -m -s /bin/bash $USERNAME
echo $USERNAME:$USERPASS | chpasswd
# Add user to sudo group
usermod -aG sudo $USERNAME

# Basic network configuration (DHCP by default with netplan/ubuntu-server)
# You might need to adjust /etc/netplan/*.yaml after first boot if needed.

# Enable SSH to start on boot
systemctl enable ssh

# Basic cleanup
apt-get -y autoremove
apt-get -y clean

echo "Initial Ubuntu Server setup complete inside chroot."
EOF_SCRIPT

chmod a+x /tmp/urfs/install-ubuntu-server.sh

# --- Run Installation Script in Chroot ---
echo "Running initial setup inside the new Ubuntu environment..."
chroot /tmp/urfs /bin/bash -c /install-ubuntu-server.sh

# --- Clean Up Chroot Script ---
rm -f /tmp/urfs/install-ubuntu-server.sh

# --- Copy Kernel Modules and Firmware (Often Needed for Hardware) ---
echo "Copying kernel modules and firmware from ChromeOS..."
KERN_VER=`uname -r`
mkdir -p /tmp/urfs/lib/modules/$KERN_VER/
cp -ar /lib/modules/$KERN_VER/* /tmp/urfs/lib/modules/$KERN_VER/ 2>/dev/null || echo "Warning: Could not copy all kernel modules."

if [ ! -d /tmp/urfs/lib/firmware/ ]; then
  mkdir -p /tmp/urfs/lib/firmware/
fi
cp -ar /lib/firmware/* /tmp/urfs/lib/firmware/ 2>/dev/null || echo "Warning: Could not copy all firmware."

# --- Unmount Chroot Filesystems ---
echo "Unmounting chroot filesystems..."
umount /tmp/urfs/proc
umount /tmp/urfs/dev/pts
umount /tmp/urfs/dev
umount /tmp/urfs/sys

# --- Prepare Kernel Repacking ---
echo "Preparing kernel repacking..."

# Kernel command line for Ubuntu
# root= is set to the target partition. console, debug, verbose are common.
# lsm.module_locking=0 is often needed for custom kernels on ChromeOS.
# init=/sbin/init is standard for Ubuntu
echo "console=tty1 debug verbose root=${target_rootfs} rootwait rw lsm.module_locking=0 init=/sbin/init" > /tmp/kernel-config-server

# Determine architecture for vbutil_kernel
vbutil_arch="x86"
if [ "$ubuntu_arch" = "armhf" ]; then
  vbutil_arch="arm"
fi

# Get the current ChromeOS kernel blob to repack with our config
current_rootfs="`rootdev -s`"
current_kernfs_num=$((${current_rootfs: -1:1}-1))
current_kernfs=${current_rootfs: 0:-1}$current_kernfs_num

echo "Repacking kernel to ${target_kern} using current ChromeOS kernel ${current_kernfs}..."
vbutil_kernel --repack ${target_kern} \
    --oldblob $current_kernfs \
    --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
    --version 1 \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --config /tmp/kernel-config-server \
    --arch $vbutil_arch

# --- Set Boot Priority ---
echo "Setting Ubuntu Server kernel partition (${target_kern}) as boot priority for next boot..."
cgpt add -i 6 -P 5 -T 1 ${target_disk} # Partition 6 (KERN-C or KERN-A), Priority 5, Tries 1

# --- Add Boot Toggle Scripts (Optional) ---
echo "Creating boot toggle scripts..."
cat > /tmp/urfs/usr/local/sbin/boot2chromeos << EOF_BOOT2C
#!/bin/bash
# Set ChromeOS as default boot
sudo cgpt add -i 6 -P 0 -S 0 ${target_disk}
echo "Next boot will be ChromeOS. Rebooting..."
sudo reboot
EOF_BOOT2C
chmod +x /tmp/urfs/usr/local/sbin/boot2chromeos

cat > /tmp/urfs/usr/local/sbin/boot2ubuntu << EOF_BOOT2U
#!/bin/bash
# Set Ubuntu as default boot
sudo cgpt add -i 6 -P 5 -S 1 ${target_disk}
echo "Next boot will be Ubuntu Server. Rebooting..."
sudo reboot
EOF_BOOT2U
chmod +x /tmp/urfs/usr/local/sbin/boot2ubuntu

# --- Cleanup Mounts ---
echo "Cleaning up mounts..."
umount /tmp/urfs

# --- Final Message ---
echo -e "
Installation of Ubuntu Server ${ubuntu_version} seems to be complete.

*** IMPORTANT ***
- Default user created: serveruser
- Default password: serverpassword  <--- CHANGE THIS AFTER FIRST LOGIN!!!
- SSH server is installed and enabled.

If Ubuntu Server fails to boot:
1. Power off your Chromebook completely.
2. Turn it back on to return to ChromeOS.
3. Review the boot parameters in /tmp/kernel-config-server and adjust if necessary.
4. Re-run the kernel repacking step manually if needed.

To make Ubuntu Server the default boot option (after confirming it works):
  Inside Ubuntu, run: sudo /usr/local/sbin/boot2ubuntu
To revert to ChromeOS:
  Inside Ubuntu, run: sudo /usr/local/sbin/boot2chromeos
  Or, from ChromeOS shell: sudo cgpt add -i 6 -P 0 -S 0 ${target_disk}

We're now ready to attempt to boot Ubuntu Server!
"

read -p "Press [Enter] to reboot and attempt to boot Ubuntu Server..."
reboot
