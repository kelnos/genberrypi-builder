#!/bin/bash

set -ex

: ${SUDO:=sudo}
: ${RPI_CHOST:=armv6j-hardfloat-linux-gnueabi}
: ${TOOLCHAIN_BIN:=/usr/bin}
: ${QEMU_STATIC:=/usr/bin/qemu-arm}
: ${PYTHON:= python}
: ${MAKE:=make}

: ${DISK_IMAGE_SIZE:= 4294967296}  # 4GB
: ${BOOTFS_SIZE:=100663296}  # 96MB

: ${STAGING_ROOT:=$(pwd)/out}

NCPUS=$(grep '^processor' /proc/cpuinfo | wc -l)

DOWNLOADS=$STAGING_ROOT/dl
SOURCES=$STAGING_ROOT/src
BOOTFS=$STAGING_ROOT/build/boot
ROOTFS=$STAGING_ROOT/build/rootfs
DISK_IMAGE=$STAGING_ROOT/build/gentoo-raspi-$(date +%Y%d%m).img

RPI_KERNEL_GIT_REPO=git://github.com/raspberrypi/linux.git
RPI_TOOLS_GIT_REPO=git://github.com/raspberrypi/tools.git
RPI_FIRMWARE_GIT_REPO=git://github.com/raspberrypi/firmware.git

BOOT_FILES="\
    COPYING.linux \
    LICENCE.broadcom \
    bootcode.bin \
    fixup.dat \
    kernel_cutdown.img \
    kernel_emergency.img \
    start.elf \
"

HOST_BINARIES="\
    curl \
    git \
    losetup \
    parted \
    qemu-arm \
    rsync \
"

STAGE3_URL_PREFIX=http://distfiles.gentoo.org/releases/arm/autobuilds
LATEST_STAGE3_FILE_URL="$STAGE3_URL_PREFIX/latest-stage3-armv6j_hardfp.txt"
STAGE3_URL=
PORTAGE_SNAPSHOT_URL=http://distfiles.gentoo.org/snapshots/portage-latest.tar.bz2

get_stage3_url() {
    if [ -z "$STAGE3_URL" ]; then
        name=$(curl $LATEST_STAGE3_FILE_URL 2>/dev/null | grep -v '^\#')
        STAGE3_URL="$STAGE3_URL_PREFIX/$name"
    fi
    echo "$STAGE3_URL"
}

git_fetch() {
    url=$1
    dir=$(basename $url .git)
    ret=0

    if [ -d $dir ]; then
        pushd $dir
        currev=$(git rev-parse HEAD)
        git pull
        newrev=$(git rev-parse HEAD)
        popd
        [ "$currev" = "$newrev" ] || ret=1
    else
        git clone $url
        ret=1
    fi

    return $ret
}

setup_loopback() {
    line=$(parted -s $1 'unit B' 'p' | awk "/^ $2 /{print}")
    offset=$(echo "$line" | awk '{print $2}')
    size=$(echo "$line" | awk '{print $4}')
    offset=${offset%%B}
    size=${size%%B}
    dev=$($SUDO losetup -o $offset --sizelimit $size -f --show $1 2>/dev/null)
    echo $dev
}

check_requirements() {
    for b in $HOST_BINARIES; do
        if ! type $b &>/dev/null; then
            echo "You need to install '$b'" >&2
            exit 1
        fi
    done

    if [ ! -x $TOOLCHAIN_BIN/$RPI_CHOST-gcc ]; then
        if type crossdev &>/dev/null; then
            echo "No toolchain found; building one..."
            $SUDO env FEATURES=-splitdebug crossdev -S -v -t $RPI_CHOST
        else
            echo "No cross toolchain found.  Either install 'crossdev' and I can install" >&2
            echo "one for you, or set TOOLCHAIN_BIN and RPI_CHOST appropriately." >&2
            exit 1
        fi
    fi

    mkdir -p $STAGING_ROOT $DOWNLOADS $SOURCES $BOOTFS $ROOTFS
}

fetch_dependencies() {
    pushd $DOWNLOADS
    if [ ! -e "$(basename $(get_stage3_url))" ]; then
        curl -O $(get_stage3_url)
    fi
    if [ ! -e "$(basename $PORTAGE_SNAPSHOT_URL)" ]; then
        curl -O $PORTAGE_SNAPSHOT_URL
    fi
    popd

    pushd $SOURCES
    git_fetch $RPI_KERNEL_GIT_REPO || rm -f linux/arch/arm/boot/Image
    git_fetch $RPI_FIRMWARE_GIT_REPO || true
    git_fetch $RPI_TOOLS_GIT_REPO || true
    popd
}

build_kernel() {
    if [ ! -f linux/arch/arm/boot/Image ]; then
        pushd linux
        ARCH=arm $MAKE bcmrpi_cutdown_defconfig
        ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE oldconfig
        ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE -j$NCPUS
        popd
    fi
}

build_bootfs() {
    for f in $BOOT_FILES; do
        cp -a $SOURCES/firmware/boot/$f $BOOTFS
    done
    pushd overlays/boot
    rsync -a . $BOOTFS
    popd
    pushd $SOURCES/tools/mkimage
    $PYTHON imagetool-uncompressed.py $SOURCES/linux/arch/arm/boot/Image
    mv kernel.img $BOOTFS
    pushd
}

build_rootfs() {
    $SUDO tar xjf $DOWNLOADS/$(basename $(get_stage3_url)) -C $ROOTFS
    $SUDO tar xjf $DOWNLOADS/$(basename $PORTAGE_SNAPSHOT_URL) -C $ROOTFS/usr
    pushd overlays/rootfs
    rsync -a . $ROOTFS
    popd
    pushd $SOURCES/linux
    $SUDO env ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE modules_install INSTALL_MOD_PATH=$ROOTFS
    popd

    $SUDO cp bootstrap.sh $ROOTFS
    $SUDO cp $QEMU_STATIC $ROOTFS/bin
    $SUDO cp /etc/resolv.conf $ROOTFS/etc

    $SUDO mount -t proc proc $ROOTFS/proc
    $SUDO mount --rbind /sys $ROOTFS/sys
    $SUDO mount --rbind /dev $ROOTFS/dev
    $SUDO mount --rbind $BOOTFS $ROOTFS/boot
    trap "$SUDO umount -fl $ROOTFS/{proc,sys,dev,boot} || true" INT QUIT TERM EXIT
    $SUDO chroot $ROOTFS /bootstrap.sh
    $SUDO umount -fl $ROOTFS/{proc,sys,dev,boot}
    trap -

    $SUDO rm $ROOTFS/bootstrap.sh $ROOTFS/bin/$(basename $QEMU_STATIC) $ROOTFS/etc/resolv.conf
    $SUDO rm -rf $ROOTFS/usr/portage/distfiles/*
    if [ $ROOTFS/boot/* != $ROOTFS/boot/\* ]; then
        $SUDO mv $ROOTFS/boot/* $BOOTFS
    fi
}

prepare_disk_image() {
    MBR_SIZE=512
    BOOTFS_START=$MBR_SIZE
    BOOTFS_END=$(expr $BOOTFS_START + $BOOTFS_SIZE - 1)
    ROOTFS_START=$(expr $BOOTFS_END + 1)
    ROOTFS_END=$(expr $DISK_IMAGE_SIZE - 1)

    rm -f $DISK_IMAGE
    dd if=/dev/zero of=$DISK_IMAGE bs=4M count=$(expr $DISK_IMAGE_SIZE / 4194304)
    parted $DISK_IMAGE -s -a minimal "mklabel msdos"
    parted $DISK_IMAGE -s -a minimal "mkpart primary fat32 ${BOOTFS_START}B ${BOOTFS_END}B"
    parted $DISK_IMAGE -s -a minimal "set 1 boot on"
    parted $DISK_IMAGE -s -a minimal "mkpart primary ext4 ${ROOTFS_START}B ${ROOTFS_END}B"
    parted $DISK_IMAGE -s -a minimal "set 2 root on"
}

populate_disk_image() {
    mkdir -p $BOOTFS.mnt
    dev=$(setup_loopback $DISK_IMAGE 1)
    $SUDO mkfs.vfat -n boot -f 2 -F 32 $dev
    $SUDO mount -o loop,noatime $dev $BOOTFS.mnt
    trap "$SUDO umount -fl $BOOTFS.mnt; $SUDO losetup -D || true" INT TERM QUIT EXIT
    $SUDO cp -a $BOOTFS/* $BOOTFS.mnt
    $SUDO umount $BOOTFS.mnt
    trap -
    rmdir $(BOOTFS).mnt

    mkdir -p $ROOTFS.mnt
    dev=$(setup_loopback $DISK_IMAGE 2)
    $SUDO mkfs.ext4 -L rootfs -M / $dev
    $SUDO mount -o loop,noatime $dev $ROOTFS.mnt
    trap "$SUDO umount -fl $ROOTFS.mnt; $SUDO losetup -D || true" INT TERM QUIT EXIT
    $SUDO cp -a $ROOTFS/* $ROOTFS.mnt
    $SUDO umount $ROOTFS.mnt
    trap -
    rmdir $ROOTFS.mnt

    $SUDO losetup -D || true
}

if [ -z "$1" ]; then
    operations="\
        check_requirements \
        fetch_dependencies \
        build_kernel \
        build_bootfs \
        build_rootfs \
        prepare_disk_image \
        populate_disk_image \
    "
else
    operations="$1"
fi

for o in $operations; do
    eval "$o"
done

echo
echo "Build complete.  Final disk image is $DISK_IMAGE"
echo
