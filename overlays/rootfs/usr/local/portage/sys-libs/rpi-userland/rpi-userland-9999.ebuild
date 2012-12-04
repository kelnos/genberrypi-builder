# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI=4

EGIT_REPO_URI="git://github.com/raspberrypi/userland.git"

inherit git-2 multilib

DESCRIPTION="Raspberry Pi userland libraries (OpenGL, OpenVG, vc, etc.)"
HOMEPAGE="https://github.com/raspberrypi/userland"

LICENSE="BSD"
SLOT="0"
KEYWORDS="~arm"
IUSE=""

RDEPEND=""
DEPEND="
	dev-util/cmake
	${RDEPEND}"

S="${WORKDIR}/userland"

src_prepare() {
	sed -e "s/arm-linux-gnueabihf/${CHOST}/g" \
		"${S}/makefiles/cmake/toolchains/arm-linux-gnueabihf.cmake" \
		>"${S}/makefiles/cmake/toolchains/${CHOST}.cmake" || die "sed failed"
}

src_compile() {
	mkdir -p "${S}/build/arm-linux/release"
	cd "${S}/build/arm-linux/release"
    cmake \
		-DCMAKE_TOOLCHAIN_FILE=../../../makefiles/cmake/toolchains/${CHOST}.cmake \
		-DCMAKE_BUILD_TYPE=Release ../../.. || die "cmake failed"
	emake || die "emake failed"
}

src_install() {
	cd "${S}"

	OPENGL_DIR="/usr/$(get_libdir)/opengl/rpi-broadcom"
	mkdir -p "${D}/${OPENGL_DIR}"
	cp -r build/lib build/include "${D}/${OPENGL_DIR}"

	dobin tvservice
	dobin vcgencmd
	dobin vchiq_test

	doinitd build/arm-linux/release/etc/init.d/vcfiled
	into /
	dosbin build/bin/vcfiled

	# a little messy...
	cd "${D}/${OPENGL_DIR}/lib"
	ln -s libEGL.so libEGL.so.1
	ln -s libGLESv2.so libGLESv2.so.2
	ln -s libOpenVG.so libOpenVG.so.1
}
