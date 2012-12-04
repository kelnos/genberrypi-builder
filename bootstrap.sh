#!/bin/bash

set -ex

PACKAGES="
	alsa-lib
	alsa-utils
	dhcpcd
	eselect-opengl
	gentoolkit
	ifplugd
	nfs-utils
	ntp
	rpi-userland
	samba
	sysklogd
	vim
	vixie-cron
"

export USE='-dbus -gtk -gtk3 -qt -qt3 -qt4 -X'

env-update
source /etc/profile

cp /usr/share/zoneinfo/UTC /etc/localtime
echo 'UTC' >/etc/timezone

ln -sf net.lo /etc/init.d/net.eth0
sed -i -e 's/^hostname=.*$/hostname="genberrypi"/' /etc/conf.d/hostname
sed -i -e 's/^127\.0\.0\.1.*/127.0.0.1\tgenberrypi localhost/' /etc/hosts

# RPi doesn't have an RTC
sed -i -e 's/clock_hctosys="YES"/clock_hctosys="NO"/' /etc/conf.d/hwclock

echo "PORTDIR_OVERLAY=/usr/local/portage" >>/etc/make.conf

# FIXME: put in proper overlay
ebuild /usr/local/portage/sys-libs/rpi-userland/rpi-userland-9999.ebuild digest

# i really don't like this
mkdir -p /etc/portage/package.keywords
cat >/etc/portage/package.keywords/rpi-bootstrap <<EOF
sys-apps/ifplugd
sys-libs/rpi-userland
EOF

emerge --sync
emerge -uD world
emerge ${PACKAGES}
rm -rf /usr/portage/distfiles/*

for svc in alsasound avahi-daemon net.eth0 ntpd sshd sysklogd vcfiled vixie-cron; do
	rc-update add ${svc} default
done

eselect opengl set rpi-broadcom

# don't allow root logins
passwd -l root

# create a regular user
useradd -m rpi
echo -e "raspberry\nraspberry" | passwd rpi
