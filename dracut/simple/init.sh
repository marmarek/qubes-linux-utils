#!/bin/sh
echo "Qubes initramfs script here:"

mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

if [ -e /dev/mapper/dmroot ] ; then 
    echo "Qubes: FATAL error: /dev/mapper/dmroot already exists?!"
fi

modprobe xenblk || modprobe xen-blkfront || echo "Qubes: Cannot load Xen Block Frontend..."

die() {
    echo "$@" >&2
    exit 1
}

echo "Waiting for /dev/xvda* devices..."
while ! [ -e /dev/xvda ]; do sleep 0.1; done

SWAP_SIZE=$(( 1024 * 1024 * 2 )) # sectors, 1GB

if [ `cat /sys/block/xvda/ro` = 1 ] ; then
    echo "Qubes: Doing COW setup for AppVM..."

    while ! [ -e /dev/xvdc ]; do sleep 0.1; done
    VOLATILE_SIZE=$(cat /sys/block/xvdc/size) # sectors
    ROOT_SIZE=$(cat /sys/block/xvda/size) # sectors
    if [ $VOLATILE_SIZE -lt $SWAP_SIZE ]; then
        die "volatile.img smaller than 1GB, cannot continue"
    fi
    sfdisk -q --unit S /dev/xvdc >/dev/null <<EOF
1,$SWAP_SIZE,S
,,L
EOF
    if [ $? -ne 0 ]; then
        echo "Qubes: failed to setup partitions on volatile device"
        exit 1
    fi
    while ! [ -e /dev/xvdc1 ]; do sleep 0.1; done
    mkswap /dev/xvdc1
    while ! [ -e /dev/xvdc2 ]; do sleep 0.1; done

    echo "0 `cat /sys/block/xvda/size` snapshot /dev/xvda /dev/xvdc2 N 16" | \
        dmsetup create dmroot || { echo "Qubes: FATAL: cannot create dmroot!"; exit 1; }
    echo Qubes: done.
else
    echo "Qubes: Doing R/W setup for TemplateVM..."
    while ! [ -e /dev/xvdc ]; do sleep 0.1; done
    sfdisk -q --unit S /dev/xvdc >/dev/null <<EOF
1,$SWAP_SIZE,S
EOF
    if [ $? -ne 0 ]; then
        die "Qubes: failed to setup partitions on volatile device"
    fi
    while ! [ -e /dev/xvdc1 ]; do sleep 0.1; done
    mkswap /dev/xvdc1
    echo "0 `cat /sys/block/xvda/size` linear /dev/xvda 0" | \
        dmsetup create dmroot || { echo "Qubes: FATAL: cannot create dmroot!"; exit 1; }
    echo Qubes: done.
fi
dmsetup mknodes dmroot

modprobe ext4

mkdir -p /sysroot
mount /dev/mapper/dmroot /sysroot -o ro
NEWROOT=/sysroot

kver="`uname -r`"
if ! [ -d "$NEWROOT/lib/modules/$kver/kernel" ]; then
    echo "Waiting for /dev/xvdd device..."
    while ! [ -e /dev/xvdd ]; do sleep 0.1; done

    # Mount only `uname -r` subdirectory, to leave the rest of /lib/modules writable
    mkdir -p /tmp/modules
    mount -n -t ext3 /dev/xvdd /tmp/modules
    if ! [ -d "$NEWROOT/lib/modules/$kver" ]; then
        mount "$NEWROOT" -o remount,rw
        mkdir -p "$NEWROOT/lib/modules/$kver"
        mount "$NEWROOT" -o remount,ro
    fi
    mount --bind "/tmp/modules/$kver" "$NEWROOT/lib/modules/$kver"
    umount /tmp/modules
    rmdir /tmp/modules
fi

umount /dev /sys /proc

exec switch_root $NEWROOT /sbin/init
