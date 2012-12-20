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
	sed -i -e "s/arm-linux-gnueabihf/${CHOST}/g" "${S}/buildme"
	#sed -i -e 's/-j 6/VERBOSE=1/' "${S}/buildme"
}

src_compile() {
	cd "${S}"
#	./buildme || die "build failed"
	mkdir -p "${S}/build/arm-linux/release"
	cd "${S}/build/arm-linux/release"
	cmake \
		-DCMAKE_TOOLCHAIN_FILE=../../../makefiles/cmake/toolchains/${CHOST}.cmake \
		-DCMAKE_BUILD_TYPE=Release ../../.. || die "cmake failed"
	emake VERBOSE=1 || die "emake failed"
}

src_install() {
	newinitd "${FILESDIR}"/init.d vcfiled

	OPENGL_DIR="/usr/$(get_libdir)/opengl/rpi-broadcom"
	mkdir -p "${D}/${OPENGL_DIR}"
	mkdir -p "${D}/${OPENGL_DIR}"/include

	cd "${S}"
	cp -r interface/khronos/include/* "${D}/${OPENGL_DIR}"/include

	cd "${S}"/build
	cp -r lib "${D}/${OPENGL_DIR}"
	# make eselect-opengl not sad
	touch "${D}/${OPENGL_DIR}"/lib/libGL.so

	cp -r inc/interface/vcos "${D}"/usr/include
	mkdir -p "${D}"/usr/$(get_libdir)
	mv "${D}/${OPENGL_DIR}"/libvc* "${D}"/usr/$(get_libdir)

	cd "${S}"/build/bin
	dobin tvservice
	dobin vcgencmd
	dobin vchiq_test

	cd "${S}"/build
	into /
	dosbin bin/vcfiled

	# a little messy...
	cd "${D}/${OPENGL_DIR}"/lib
	ln -s libEGL.so libEGL.so.1
	ln -s libGLESv2.so libGLESv2.so.2
	ln -s libOpenVG.so libOpenVG.so.1
}
