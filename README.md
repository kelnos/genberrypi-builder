# Gentoo Raspberry Pi Image Builder #

This contains a script that will build a 4GB (default) disk image that
you can write to an SD card to boot a
[Raspberry Pi](http://raspberrypi.org/).

It installs [Gentoo Linux](http://gentoo.org/).

Please note that I'm not offering any support for this.  It works today,
but new versions of Gentoo packages released tomorrow may break it.  If
you want to fix it and submit a patch, that's great, but I'm not going
to fix any problems with it until and unless I personally run into them.

I'm also not a fountain of knowledge for all things Raspberry Pi.  If
you need help figuring out how to get a particular piece of software running
on the device, or... well, anything, really... you should head over to the
[Raspberry Pi Wiki](http://elinux.org/RaspberryPiBoard), the
[Raspberry Pi Forum](http://www.raspberrypi.org/phpBB3/), or, as a last
resort, our good pal [Google](http://google.com/).

## Why? ##

You might suggest that this is slightly insane, and that no reasonable
person would want to install a source-based distro on a relatively
underpowered ARM board.  You'd probably be right.

But, I wanted to do it for some reason, so I did it.

## How? ##

Just run `./build-disk-image.sh` from the root of the git repo.  The final
image will end up in `./out/build/`.

Currently all of the follwing must be true for this to work:

* You're running Gentoo Linux.
* You have the `crossdev` package installed.
* You have `binfmt_misc` support built into your kernel (or it's available
  as a module).
* You have root access on the box, and `sudo` is set up so you can run
  anything (without a password will be easier).
* You're on an architecture that can run QEmu, more specifically the
  "user" variant of it that can run non-native apps as if they were native.
* There are a bunch of other tools you'll need installed, but the script
  will tell you on startup if you're missing any of them.

It will likely take a *very* long time, so be prepared to wait.

## Post Install ##

At the end, the script will print out the full path to your SD card image.
You'll want to attach your SD card to your computer via some means, and
run a command that looks something like this:

    sudo dd if=<path_to_disk_image> of=/dev/<sdcard_device> bs=4M

## The Details ##

The builder is not really the best.  It does some unfortunate things.
You may think of this as a to-do list.

* Gentoo's cross tools fail to build some packages properly.  Instead of
  figuring out why and fixing them, I chroot into the ARM rootfs, and
  use `qemu-arm` to emerge the packages "natively".  Unfortunately this
  is very slow.
* It will pollute your crossdev-created sysroot (in
  `/usr/armv6j-hardfloat-linux-gnueabi/`) with all the packages it builds
  for the Raspberri Pi, and then does not clean up after itself.  For this
  reason, I suggest you back it up first.
* It adds some stuff to your `package.unmask` and `package.keywords`
  that it probably shouldn't.
* It includes an ebuild for `rpi-userland` which fetches, builds, and
  installs the OpenGL ES, OpenVG, etc. libraries.  This ebuild should
  really go in an overlay.
* It grabs the Raspberry Pi kernel from GitHub, but I haven't created an
  ebuild for it so you can have the sources on the device itself.  You
  probably don't really want to build a kernel on the device, but some
  ebuilds may require that it be present.
* It pulls down a portage snapshot, unpacks it, and then later updates it.
  Really it could just rsync from the build system it's running on.
* It assumes you're running Gentoo on the build machine.  You really have to
  be if you want to be able to cross-emerge the packages to put in the
  rootfs image.  However, if you really wanted to, you could faux-native
  build all the packages inside the ARM chroot, using QEmu.  In that case,
  you don't even need the cross-compiler (though you might want one to build
  the kernel faster).  But anyway, the script doesn't support this (yet).
* In theory, you could even build on MacOS X using
  [XBinary](http://www.osxbook.com/software/xbinary/) for the ARM-chrooting,
  and either build everything in there, or install
  [Gentoo Prefix](http://www.gentoo.org/proj/en/gentoo-alt/prefix/) on your
  Mac to handle the cross-emerging parts.

There are also some things I find annoying that aren't really within
my control:

* It uses `armv6j-hardfloat-linux-gnueabi` as the host tuple (aka `CHOST`
  in Gentoo-land), rather than the (IMO) more-sane `arm-linux-gnueabihf`
  tuple that the Debian guys decided on.  I don't think of "hardfloat" as
  a "vendor".  The last part of the tuple generally indicates ABI
  compatibility, which is where the hard-float nature of the builds comes
  in.  Specifying a more-specific "armv6j" is useful to denote the lowest
  architecture level supported (much in the same way that "i386", "i686",
  etc. are used for x86 builds).  Anyway: this tuple is what crossdev
  recognizes, and that's how the Gentoo stage3 we bootstrap from was
  built, and I'm not interested in changing (and maintaining!) that much
  of the system. &lt;/bike-shed-naming-rant&gt;
* The Gentoo arch is still called `arm`, even though the hard-float nature
  of this build is entirely binary-incompatible with any normal Gentoo
  `arm` build.  The Debian guys decided to use `armhf` as their hard-float
  architecture, which I wish Gentoo had done.  I guess it matters less for
  a source-based distribution, but it's certainly possible that some
  packages that are unmasked and stable and working on a soft-float ARM
  system aren't particularly awesome when you build them using hard-float,
  and it would probably be nice to be able to treat them as a separate
  arch for unstable/stable keywording and masking purposes.

## Other Useful Information ##

### MOAR PACKAGES ###

This builder just builds a base system to get you started.  No X or
anything graphical at all.  You can edit the script to build more stuff,
but be aware that it's highly likely that other packages will fail to
cross-compile, and you may spend more time figuring out what they are,
adding them to the cross-compile blacklist, and restarting the process,
than it would take to just build the minimal system and then build directly
on the Raspberry Pi (while ideally using distcc to distribute the dirty
work to the cross-compiler on your build machine).

### Larger SD Cards ###

As I said, this'll build a 4GB disk image, and will use about 1.7GB of it.
You will likely have a larger SD card.  You can export the `DISK_IMAGE_SIZE`
environment variable to set a different size.  Specify the size in bytes.

Relatedly, I create a 96MB vfat partition to store the kernel and other boot
files, which barely take up 20MB.  If you want to make this partition smaller
(or larger; perhaps you want to play with different kernels and keep them
handy at all times), you can export the `BOOTFS_SIZE` env var before
running the script.  Again: the size is in bytes.

Your other option is to resize the filesystem after installing it, by first
using `parted` to expand the partition to the full size of the SD card, and
then using `resize2fs` to expand the filesystem.  This might be a better
choice, as writing out a mostly-empty disk image to your SD card will
take quite a while, whereas expanding a filesystem should be rather quick,
since it only needs to write out some new superblocks and adjust some
metadata.

### Swap ###

I don't create any swap.  Depending on your Raspberry Pi model's RAM, and
your intended use of the device, you might want some.  You can either set
`DISK_IMAGE_SIZE` a little smaller than the size of your SD card and
create your own swap partition later in the remaining space, or you can
create swap files and put them on the rootfs.  Or you can add (optional!)
support to the script and send me a patch.

As a note, after a fresh boot, the system is using about 20MB of RAM, with
about 420MB free.  The kernel and GPU eat the rest.

### Tweaks ###

There's a config file on the boot partition called `config.txt`.  There
are a bunch of options you can put in it, and many of them very well
documented
[here](https://raw.github.com/Evilpaul/RPi-config/master/config.txt).
There's also good documentation on [the
wiki](http://elinux.org/RPi_config.txt).  However, here are a few
highlights:

* `gpu_mem=` -- sets the amount of memory allocated to the GPU
* `cmdline=` -- sets the command line passed to the kernel
* `arm_freq=` -- lets you overclock (and possibly) underclock the CPU

If you use the 3.6.x kernel and LKG62 (or above) GPU firmware,
there's apparently support for runtime dynamic allocation of memory
between the CPU and GPU.  Which is pretty damn cool, if you ask me.
I haven't had a chance to test this, or play around with the newer
kernel yet, so it's not enabled.  If you're truly adventurous, you
can set `RPI_USE_EXPERIMENTAL` to something non-blank and it'll
build you some cool goodies.

## Acknowledgements ##

Well, I did write this monster of a script all by my lonesome, but I do
need to thank the Gentoo developers in general for keeping at it after
all those years of ricer jokes, and to the guys who wrote `crossdev` and
the various cross-emerge tools for helping make the build process at least
a bit faster than it otherwise would be.
