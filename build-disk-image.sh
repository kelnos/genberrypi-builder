#!/bin/bash

set -e

: ${SUDO:=sudo}
: ${RPI_ARCH:=armv6j}
: ${RPI_CPU:=arm1176jzf-s}
: ${RPI_CHOST:=${RPI_ARCH}-hardfloat-linux-gnueabi}
: ${TOOLCHAIN_BIN:=/usr/bin}
: ${QEMU_STATIC:=qemu-arm}
: ${PYTHON:=python}
: ${MAKE:=make}

: ${DISK_IMAGE_SIZE:= 4294967296}  # 4GB
: ${BOOTFS_SIZE:=100663296}  # 96MB

: ${STAGING_ROOT:=$(pwd)/out}

NCPUS=$(grep '^processor' /proc/cpuinfo | wc -l)

DOWNLOADS=$STAGING_ROOT/dl
SOURCES=$STAGING_ROOT/src
KERNELBIN=$STAGING_ROOT/build/kernel
BOOTFS=$STAGING_ROOT/build/boot
ROOTFS=$STAGING_ROOT/build/rootfs
DISK_IMAGE=$STAGING_ROOT/build/gentoo-raspi-$(date +%Y%d%m).img

RPI_KERNEL_GIT_REPO=git://github.com/raspberrypi/linux.git
RPI_TOOLS_GIT_REPO=git://github.com/raspberrypi/tools.git
RPI_FIRMWARE_GIT_REPO=git://github.com/raspberrypi/firmware.git

EXPERIMENTAL_KERNEL_BRANCH='rpi-3.6.y'
EXPERIMENTAL_FIRMWARE_BRANCH='next'

PACKAGES="\
    alsa-lib \
    alsa-utils \
    avahi \
    dhcpcd \
    eselect-opengl \
    gentoolkit \
    ifplugd \
    nss-mdns \
    nfs-utils \
    ntp \
    rpi-userland \
    samba \
    app-misc/screen \
    sudo \
    sysklogd \
    vim \
    vixie-cron \
"

CROSS_COMPILE_HALL_OF_SHAME="\
    alsa-utils \
    coreutils \
    dialog \
    elfutils \
    gdbm \
    mpc \
    pam \
    perl \
    <python-3.0.0 \
    >=python-3.0.0 \
    rpcbind \
    samba \
"

PROBLEMATIC_PACKAGES="\
    net-tools \
    openrc \
"

SERVICES_BOOT="\
    alsasound \
    avahi-daemon \
"

SERVICES_DEFAULT="\
    net.eth0 \
    ntpd \
    sshd \
    sysklogd \
    vcfiled \
    vixie-cron \
"

BOOT_FILES="
    COPYING.linux
    LICENCE.broadcom
    bootcode.bin
    fixup.dat
    start.elf
"

HOST_BINARIES="
    crossdev
    curl
    git
    losetup
    mkfs.vfat
    parted
    $QEMU_STATIC
    rsync
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
        echo -n "Updating git repo '$dir'..."
        git pull &>/dev/null
        echo ' done.'
        newrev=$(git rev-parse HEAD)
        popd
        [ "$currev" = "$newrev" ] || ret=1
    else
        echo -n "Cloning git repo '$url'..."
        git clone --depth=1 $url # shallow clone
        echo ' done.'
        ret=1
    fi

    return $ret
}

git_refresh_branch() {
    pushd $1
    if ! git branch | grep -q "* $2"; then
        if git branch | grep -q "$2"; then
            git checkout $2
        else
            git checkout -t origin/$2
        fi
        git pull
    fi
    popd
}

url_fetch() {
    url=$1
    filename=$(basename "$url")

    if [ ! -e "$filename" ]; then
        echo -n "Fetching $url..."
	if type axel >/dev/null 2>&1 ; then # prefer axel over curl
            axel -a "$url"
	else # curl fallback
            curl -O "$url" &>/dev/null
	fi
        echo " done."
    fi
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

run_in_chroot() {
    $SUDO cp $(which $QEMU_STATIC 2>/dev/null) $ROOTFS/$ARM_INTERP_DIR
    $SUDO cp /etc/resolv.conf $ROOTFS/etc
    $SUDO mount -t proc proc $ROOTFS/proc
    $SUDO mount --rbind /sys $ROOTFS/sys
    $SUDO mount --rbind /dev $ROOTFS/dev
    $SUDO mount --rbind $BOOTFS $ROOTFS/boot
    trap "$SUDO umount -fl $ROOTFS/{proc,sys,dev,boot} || true" EXIT

    $SUDO chroot $ROOTFS "$@"

    $SUDO umount -fl $ROOTFS/{proc,sys,dev,boot}
    trap - EXIT
    $SUDO rm -f $ROOTFS/$ARM_INTERP_DIR/$QEMU_STATIC $ROOTFS/etc/resolv.conf
}

check_requirements() {
    for b in $HOST_BINARIES; do
        if ! type $b &>/dev/null; then
            echo "You need to install '$b'" >&2
            exit 1
        fi
    done

    if [ ! -e /proc/sys/fs/binfmt_misc/arm ]; then
        echo 'No handler set up for ARM binaries.  I will do that for you.'
        $SUDO ./arm-qemu-binfmt.sh
    fi

    arm_interp_path=$(awk '/^interpreter/{ print $2 }' /proc/sys/fs/binfmt_misc/arm)
    arm_interp_name=$(basename $arm_interp_path)
    if [ "$arm_interp_name" != "$QEMU_STATIC" ]; then
        echo "We want to use '$QEMU_STATIC' to run ARM binaries in the chroot, but" >&2
        echo "your system is set up to use '$arm_interp_name'.  Please fix this" >&2
        echo "and restart this script." >&2
        exit 1
    fi
    ARM_INTERP_DIR=$(dirname $arm_interp_path)

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

    mkdir -p $STAGING_ROOT $DOWNLOADS $SOURCES $KERNELBIN $BOOTFS $ROOTFS
}

fetch_dependencies() {
    pushd $DOWNLOADS
    url_fetch $(get_stage3_url)
    url_fetch $PORTAGE_SNAPSHOT_URL
    popd

    pushd $SOURCES
    git_fetch $RPI_KERNEL_GIT_REPO || rm -f $KERNELBIN/*.img
    git_fetch $RPI_FIRMWARE_GIT_REPO || true
    git_fetch $RPI_TOOLS_GIT_REPO || true
    popd

    if [ -n "$RPI_USE_EXPERIMENTAL" ]; then
        git_refresh_branch $SOURCES/linux $EXPERIMENTAL_KERNEL_BRANCH
        git_refresh_branch $SOURCES/firmware $EXPERIMENTAL_FIRMWARE_BRANCH
    fi
}

build_kernel() {
    configsuffix=$1
    fullconfig="bcmrpi${configsuffix}_defconfig"

    pushd $SOURCES/linux
    echo "Building kernel with config $fullconfig..."
    ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE clean
    ARCH=arm $MAKE $fullconfig
    ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE oldconfig
    ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE -j$NCPUS
    ARCH=arm CROSS_COMPILE=$TOOLCHAIN_BIN/$RPI_CHOST- $MAKE modules_install INSTALL_MOD_PATH=$KERNELBIN
    popd

    pushd $SOURCES/tools/mkimage
    $PYTHON imagetool-uncompressed.py $SOURCES/linux/arch/arm/boot/Image
    mv kernel.img "$KERNELBIN/kernel${configsuffix}.img"
    popd
}

build_kernels() {
    for configsuffix in '' _cutdown _quick; do
        if [ ! -f "$KERNELBIN/kernel${configsuffix}.img" ]; then
            build_kernel $configsuffix
        fi
    done
}

build_bootfs() {
    echo
    echo "Assembling boot file system"
    echo

    for f in $BOOT_FILES; do
        cp -a $SOURCES/firmware/boot/$f $BOOTFS
    done
    pushd overlays/boot
    $SUDO rsync -a . $BOOTFS
    popd

    cp $KERNELBIN/*.img $BOOTFS
}

build_rootfs() {
    echo
    echo "Assembling root filesystem"
    echo

    echo -n "Unpacking stage3 tarball..."
    $SUDO tar xjf $DOWNLOADS/$(basename $(get_stage3_url)) -C $ROOTFS
    echo " done."
    echo -n "Unpacking portage snapshot..."
    $SUDO tar xjf $DOWNLOADS/$(basename $PORTAGE_SNAPSHOT_URL) -C $ROOTFS/usr
    echo " done."

    # weird.
    $SUDO ln -sfn ../usr/portage/profiles/default/linux/arm/10.0 $ROOTFS/etc/make.profile

    pushd overlays/rootfs
    echo -n "Copying rootfs overlay..."
    $SUDO rsync -a . $ROOTFS &>/dev/null
    echo " done."
    popd

    pushd $SOURCES/linux
    echo -n "Installing kernel modules & firmware..."
    mkdir -p $ROOTFS/lib
    $SUDO cp -a $KERNELBIN/lib/* $ROOTFS/lib
    echo " done."
    popd
}

prepare_rootfs() {
    $SUDO cp $ROOTFS/usr/share/zoneinfo/UTC $ROOTFS/etc/localtime
    echo 'UTC' | $SUDO tee $ROOTFS/etc/timezone &>/dev/null

    $SUDO ln -sf net.lo $ROOTFS/etc/init.d/net.eth0

    if [ -n "$RPI_USE_EXPERIMENTAL" ]; then
        use_exp='rpi-experimental '
    fi

    echo "USE='${use_exp}-acl -cups -dbus -gtk -gtk3 -introspection -nls -qt -qt3 -qt4 -X'" | $SUDO tee -a $ROOTFS/etc/make.conf &>/dev/null
    echo "PORTDIR_OVERLAY=/usr/local/portage" | $SUDO tee -a $ROOTFS/etc/make.conf &>/dev/null

    # don't generate all locales
    $SUDO sed -i -e 's/^#en_US.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/' $ROOTFS/etc/locale.gen

    # more correct CFLAGS
    $SUDO sed -i -e "s/-march=[^ ]\+/-mcpu=$RPI_CPU/g" $ROOTFS/etc/make.conf

    # i really don't like this
    $SUDO mkdir -p $ROOTFS/etc/portage/package.keywords
    cat <<EOF | $SUDO tee $ROOTFS/etc/portage/package.keywords/rpi-bootstrap &>/dev/null
sys-apps/ifplugd
sys-auth/nss-mdns **
sys-libs/rpi-userland
EOF
    # for some reason linux-headers-3.6 is missing a header that net-tools
    # needs.  we don't really want to go over to eudev yet, but some packages
    # seem to get a little confused and try to pull both udev and eudev in.
    $SUDO mkdir -p $ROOTFS/etc/portage/package.mask
    cat <<EOF | $SUDO tee $ROOTFS/etc/portage/package.mask/rpi-bootstrap &>/dev/null
=sys-kernel/linux-headers-3.6
sys-fs/eudev
EOF

    run_in_chroot /usr/bin/emerge --sync
    run_in_chroot emerge --sync
}

# don't use this.  it doesn't work.
change_rootfs_chost() {
    old_chost=$(source $ROOTFS/etc/make.conf && echo $CHOST)
    if [ "$old_chost" != "$RPI_CHOST" ]; then
        echo "Changing CHOST from $old_chost to $RPI_CHOST..."

        $SUDO sed -i -e "s/^CHOST=.*/CHOST=$RPI_CHOST/" $ROOTFS/etc/make.conf
        $SUDO sed -i -e "s/-march=[^ ]\+/-mcpu=$RPI_CPU/g" $ROOTFS/etc/make.conf

        $SUDO emerge-wrapper --init
        $SUDO env CHOST=$RPI_CHOST CBUILD=$(gcc -dumpmachine) ROOT=/usr/$RPI_CHOST PORTAGE_CONFIGROOT=$ROOTFS MAKEOPTS="-j$NCPUS" PORTDIR_OVERLAY=$ROOTFS/usr/local/portage PKGDIR=$ROOTFS/usr/portage/packages $RPI_CHOST-emerge --buildpkg --oneshot --usepkg binutils gcc glibc || \
            { \
               run_in_chroot env MAKEOPTS="-j$NCPUS" emerge --oneshot --buildpkg mpc && \
               $SUDO env CHOST=$RPI_CHOST CBUILD=$(gcc -dumpmachine) ROOT=/usr/$RPI_CHOST PORTAGE_CONFIGROOT=$ROOTFS MAKEOPTS="-j$NCPUS" PORTDIR_OVERLAY=$ROOTFS/usr/local/portage PKGDIR=$ROOTFS/usr/portage/packages $RPI_CHOST-emerge --buildpkg --oneshot --usepkg binutils gcc glibc; \
            }
        run_in_chroot env MAKEOPTS="-j$NCPUS" emerge --oneshot --usepkgonly binutils gcc glibc
        $SUDO rm -f \
            $ROOTFS/etc/env.d/*gcc-$OLD_CHOST \
            $ROOTFS/etc/env.d/binutils/*$OLD_CHOST* \
            $ROOTFS/etc/env.d/gcc/*$OLD_CHOST*
    fi
}

crossbuild_packages() {
    echo "Cross-building packages..."

    NCPUS=$(grep '^processor' /proc/cpuinfo | wc -l)
    $SUDO mkdir -p $ROOTFS/usr/portage/packages

    # some packages hate cross-building, so build them in the chroot
    run_in_chroot /usr/bin/env MAKEOPTS="-j$NCPUS" emerge --buildpkg --usepkg --oneshot $CROSS_COMPILE_HALL_OF_SHAME

    $SUDO emerge-wrapper --init
    $SUDO env CHOST=$RPI_CHOST CBUILD=$(gcc -dumpmachine) ROOT=/usr/$RPI_CHOST PORTAGE_CONFIGROOT=$ROOTFS MAKEOPTS="-j$NCPUS" PORTDIR_OVERLAY=$ROOTFS/usr/local/portage PKGDIR=$ROOTFS/usr/portage/packages $RPI_CHOST-emerge --buildpkg --oneshot --usepkg system
    $SUDO env CHOST=$RPI_CHOST CBUILD=$(gcc -dumpmachine) ROOT=/usr/$RPI_CHOST PORTAGE_CONFIGROOT=$ROOTFS MAKEOPTS="-j$NCPUS" PORTDIR_OVERLAY=$ROOTFS/usr/local/portage PKGDIR=$ROOTFS/usr/portage/packages $RPI_CHOST-emerge --emptytree --buildpkg --usepkg $PACKAGES
}

bootstrap_rootfs() {
    echo "Chrooting into rootfs to do second-stage bootstrap..."

    run_in_chroot /bin/bash -e -c "
env-update
source /etc/profile

emerge --usepkgonly $PROBLEMATIC_PACKAGES
emerge --usepkgonly system
emerge --usepkgonly --emptytree $PACKAGES

# just allow it to auto-merge trivial stuff
etc-update -p

for svc in $SERVICES_BOOT; do
    rc-update add \$svc boot
done

for svc in $SERVICES_DEFAULT; do
    rc-update add \$svc default
done

eselect opengl set rpi-broadcom

# don't allow root logins
passwd -l root

# create a regular user
useradd -m rpi -G adm,audio,video,wheel
echo -e \"raspberry\nraspberry\" | passwd rpi
"
    # some of this stuff is here to avoid 'updated conf file' messages
    # after all the emerging we do above.

    # set a reasonable hostname
    $SUDO sed -i -e 's/^hostname=.*$/hostname="genberrypi"/' $ROOTFS/etc/conf.d/hostname
    $SUDO sed -i -e 's/^127\.0\.0\.1.*/127.0.0.1\tgenberrypi localhost/' $ROOTFS/etc/hosts

    # RPi doesn't have an RTC
    $SUDO sed -i -e 's/^#\?clock_hctosys=.*/clock_hctosys="NO"/' $ROOTFS/etc/conf.d/hwclock
    $SUDO sed -i -e 's/^#\?clock_systohc=.*/clock_systohc="NO"/' $ROOTFS/etc/conf.d/hwclock

    # modules: sound!
    echo 'modules="snd-bcm2835"' | $SUDO tee -a $ROOTFS/etc/conf.d/modules &>/dev/null

    # correct serial console port and speed for getty
    $SUDO sed -i -e '/^s0:/s/ttyS0/ttyAMA0/; /^s0:/s/9600/115200/' $ROOTFS/etc/inittab
    # really don't need 6 vc gettys
    for i in 3 4 5 6; do
        $SUDO sed -i -e "s/^c$i:/#c$i:/" $ROOTFS/etc/inittab
    done

    # sudo access; gotta do this *after* sudo gets installed
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' | $SUDO tee -a $ROOTFS/etc/sudoers >/dev/null

    # enable multicast dns resolution.  i really don't understand why
    # everyone doesn't do this by default nowadays.
    $SUDO sed -i -e 's/^\(hosts:\s\+\).*/\1files mdns4_minimal [NOTFOUND=return] dns mdns4/' $ROOTFS/etc/nsswitch.conf

    $SUDO rm -rf $ROOTFS/usr/portage/distfiles/*
    if [ $ROOTFS/boot/* != $ROOTFS/boot/\* ]; then
        $SUDO mv $ROOTFS/boot/* $BOOTFS
    fi
}

prepare_disk_image() {
    echo "Preparing disk image..."

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
}

populate_disk_image() {
    echo "Populating disk image..."

    mkdir -p $BOOTFS.mnt
    dev=$(setup_loopback $DISK_IMAGE 1)
    $SUDO mkfs.vfat -n boot -f 2 -F 32 $dev
    $SUDO mount -o loop,noatime $dev $BOOTFS.mnt
    trap "$SUDO umount -fl $BOOTFS.mnt; $SUDO losetup -D || true" EXIT
    $SUDO cp -r $BOOTFS/* $BOOTFS.mnt
    $SUDO umount $BOOTFS.mnt
    trap - EXIT
    rmdir $BOOTFS.mnt

    mkdir -p $ROOTFS.mnt
    dev=$(setup_loopback $DISK_IMAGE 2)
    $SUDO mkfs.ext4 -L rootfs -M / $dev
    $SUDO mount -o loop,noatime $dev $ROOTFS.mnt
    trap "$SUDO umount -fl $ROOTFS.mnt; $SUDO losetup -D || true" EXIT
    $SUDO cp -a $ROOTFS/* $ROOTFS.mnt
    $SUDO umount $ROOTFS.mnt
    trap - EXIT
    rmdir $ROOTFS.mnt

    $SUDO losetup -D || true
}

if [ -z "$1" ]; then
    operations="\
        check_requirements \
        fetch_dependencies \
        build_kernels \
        build_bootfs \
        build_rootfs \
        prepare_rootfs \
        crossbuild_packages \
        bootstrap_rootfs \
        prepare_disk_image \
        populate_disk_image \
    "
else
    operations="check_requirements $1"
fi

for o in $operations; do
    eval "$o"
done

echo
echo "Build complete.  Final disk image is $DISK_IMAGE"
echo
