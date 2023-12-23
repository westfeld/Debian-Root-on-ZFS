#!/usr/bin/bash

# Documentation ZFS on Linux
# https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Bookworm%20Root%20on%20ZFS.html

# Documentation Hetzner Server on ZFS
# https://github.com/terem42/zfs-hetzner-vm

# Disk device to be used for the ZFS root disk
# ATTENTION disk will be erased
# Use by-id to prevent mounting the wrong disk
DISK="/dev/disk/by-id/usb-090c_1000_11110300001251-0:0"
# new hostname for the Debian server
NEW_HOSTNAME="glacier"
# network interface to use to connect to the net via DHCP
NETWORK_INTERFACE_NAME="enp5s0"
# Mount point where to mount the newly created ZFS datasets
NROOT="/m"
# Favorite mirror
DEB_MIRROR=http://mirror.netcologne.de/debian
# Security mirror
SEC_MIRROR=http://mirror.netcologne.de/debian-security


# ZFS install Punkt 6 fehlt noch

############## HELPER FUNCTIONS ############################

# install ZFS support on live Debian disk
function install_zfs () {
    sed -i .bak -e 's/$/ contrib/g' /etc/apt/sources.list 
    apt update
    apt install -y zfs-dkms zfsutils-linux dkms debootstrap gdisk
}

# helper function to execute a command under the new installation
function chroot_execute {
  chroot $NROOT bash -c "$1"
}

# create all necessary bind mounts and chroot into new system
function enter_chroot () {
   mount --make-private --rbind /dev  $NROOT/dev
   mount --make-private --rbind /proc $NROOT/proc
   mount --make-private --rbind /sys  $NROOT/sys
   chroot $NROOT /bin/env DISK=$DISK bash --login
}



# helper function to import ZFS pools and mount disks
# useful if one wants to resume system creation
function mount_pools_temp () {
    zpool import -f -d "${DISK}-part2" -R $NROOT bpool
    zpool import -f -d "${DISK}-part3" -R $NROOT rpool
    zfs mount rpool/ROOT/debian
}


############## PREPARE DISKS ##############################

# wipe disk and create partitions
function prepare_disk () {
    wipefs -a $DISK
    blkdiscard -f $DISK
    sgdisk --zap-all $DISK
    sgdisk -a1 -n1:24k:+512M -t1:EF00 $DISK # UEFI partition
    sgdisk -n2:0:+1G     -t2:BF01 $DISK # boot partition
    sgdisk -n3:0:0       -t3:BF00 $DISK # root partition
    udevadm settle
}

function create_boot_pool () {
    echo "creating boot pool ${DISK}-part2"
    zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R $NROOT \
    bpool "${DISK}-part2"
}

function create_root_pool () {
    echo "creating root pool ${DISK}-part3"
    zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/ -R $NROOT \
    rpool "${DISK}-part3"
}

function create_boot_datasets () {
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT
    zfs create -o mountpoint=/boot bpool/BOOT/debian
}

function create_root_datasets () {
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
    zfs mount rpool/ROOT/debian

    zfs create                     rpool/ROOT/debian/home
    zfs create -o mountpoint=/root rpool/ROOT/debian/home/root
    chmod 700 /mnt/root
    zfs create -o canmount=off     rpool/ROOT/debian/var
    zfs create -o canmount=off     rpool/ROOT/debian/var/lib
    zfs create                     rpool/ROOT/debian/var/log
    zfs create                     rpool/ROOT/debian/var/spool
    zfs create -o com.sun:auto-snapshot=false  rpool/ROOT/debian/var/tmp
    chmod 1777 $NROOT/var/tmp
    zfs create -o canmount=off     rpool/ROOT/debian/usr
    zfs create                     rpool/ROOT/debian/usr/local
    zfs create -o com.sun:auto-snapshot=false rpool/ROOT/debian/var/lib/docker
    zfs create -o com.sun:auto-snapshot=false  rpool/ROOT/debian/var/cache
    zfs create -o com.sun:auto-snapshot=false  rpool/ROOT/debian/tmp
    zfs create                     rpool/ROOT/debian/var/www
    zfs create                     rpool/ROOT/debian/etc
    chmod 1777 $NROOT/tmp
}


############## INSTALL SYSTEM #############################

# install base system to newly created zpool
function install_debian () {
    debootstrap bookworm $NROOT $DEB_MIRROR
}

# add rpool/etc to bootup that it is mounted before root
function add_etc_to_bootup () {
   if ! test -f $NROOT/etc/defaults/zfs; then
       echo "ZFS_INITRD_ADDITIONAL_DATASETS=rpool/etc" > $NROOT/etc/default/zfs
   fi
}

# add ZFS cache to new system
function add_zfs_cache () {
    mkdir $NROOT/etc/zfs
    cp /etc/zfs/zpool.cache $NROOT/etc/zfs
}

# create sources file with favorite mirror
function create_sources_list () {
    cat > $NROOT/etc/apt/sources.list << CONF
deb $DEB_MIRROR bookworm main contrib bookworm-updates non-free-firmware
deb-src $DEB_MIRROR bookworm main contrib bookworm-updates non-free-firmware

deb $SEC_MIRROR bookworm-security main contrib non-free-firmware
deb-src $SEC_MIRROR bookworm-security main contrib non-free-firmware

CONF
}
# configure network using systemd networking
function configure_systemd_dhcp_network () {
    echo $NEW_HOSTNAME > $NROOT/etc/hostname
    cat > $NROOT/etc/hosts << CONF
127.0.1.1 $NEW_HOSTNAME
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
CONF
    cat > $NROOT/etc/systemd/network/10-eth0.network << CONF
[Match]
Name=$NETWORK_INTERFACE_NAME

[Network]
DHCP=ipv4
IPv6AcceptRA=True
CONF

    chroot_execute "systemctl enable systemd-networkd.service"
    chroot_execute "systemctl enable systemd-resolved.service"
}

#post installation ZFS install on new system
function install_zfs_support () {
    apt install --yes console-setup locales
    apt install --yes dpkg-dev linux-headers-generic linux-image-generic
    apt install --yes zfs-initramfs
    echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf
}

