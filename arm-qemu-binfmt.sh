#!/bin/bash

set -e

# load the binfmt_misc module
if [ ! -d /proc/sys/fs/binfmt_misc ]; then
    /sbin/modprobe binfmt_misc
fi
if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
fi

echo   ':arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/bin/qemu-arm:' > /proc/sys/fs/binfmt_misc/register
