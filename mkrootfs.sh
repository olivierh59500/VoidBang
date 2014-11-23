#!/bin/sh
#-
# Copyright (c) 2013-2014 Juan Romero Pardines.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#-

readonly PROGNAME=$(basename $0)
readonly ARCH=$(uname -m)

trap 'die "Interrupted! exiting..."' INT TERM HUP


info_msg() {
    printf "\033[1m$@\n\033[m"
}

die() {
    echo "FATAL: $@"
    umount_pseudofs
    [ -d "$rootfs" ] && rm -rf $rootfs
    exit 1
}

usage() {
    cat <<_EOF
Usage: $PROGNAME [options] <platform>

Supported platforms: cubieboard2, odroid-u2, rpi

Options
    -b <syspkg> Set an alternative base-system package (defaults to base-system)
    -c <dir>    Set XBPS cache directory (defaults to /var/cache/xbps)
    -C <file>   Full path to the XBPS configuration file
    -h          Show this help
    -p <pkgs>   Additional packages to install into the rootfs (separated by blanks)
    -r <repo>   Set XBPS repository (may be set multiple times)
    -V          Show version
_EOF
}

mount_pseudofs() {
    for f in dev proc sys; do
        [ ! -d $rootfs/$f ] && mkdir -p $rootfs/$f
        mount -r --bind /$f $rootfs/$f
    done
}

umount_pseudofs() {
    for f in dev proc sys; do
        umount -f $rootfs/$f >/dev/null 2>&1
    done
}

run_cmd_target() {
    info_msg "Running $@ for target $_ARCH ..."
    eval XBPS_TARGET_ARCH=${_ARCH} "$@"
    [ $? -ne 0 ] && die "Failed to run $@"
}

run_cmd() {
    info_msg "Running $@ ..."
    eval "$@"
    [ $? -ne 0 ] && die "Failed to run $@"
}

register_binfmt() {
    if [ "$ARCH" = "${_ARCH}" ]; then
        return 0
    fi
    case "${_ARCH}" in
        armv?l)
            echo ':arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:' > /proc/sys/fs/binfmt_misc/register
            cp -f $(which qemu-arm-static) $rootfs/usr/bin || die "failed to copy qemu-arm-static to the rootfs"
            ;;
        *)
            die "Unknown target architecture!"
            ;;
    esac
}

: ${XBPS_REPOSITORY:=--repository=http://repo.voidlinux.eu/current}
: ${XBPS_CACHEDIR:=--cachedir=/var/cache/xbps}
: ${PKGBASE:=base-system}
#
# main()
#
while getopts "b:C:c:hp:r:V" opt; do
    case $opt in
        b) PKGBASE="$OPTARG";;
        C) XBPS_CONFFILE="-C $OPTARG";;
        c) XBPS_CACHEDIR="--cachedir=$OPTARG";;
        h) usage; exit 0;;
        p) EXTRA_PKGS="$OPTARG";;
        r) XBPS_REPOSITORY="--repository=$OPTARG $XBPS_REPOSITORY";;
        V) echo "$PROGNAME 0.22 "; exit 0;;
    esac
done
shift $(($OPTIND - 1))

PLATFORM="$1"

if [ -z "$PLATFORM" ]; then
    echo "$PROGNAME: platform was not set!"
    usage; exit 1
fi

case "$PLATFORM" in
    cubieboard2) _ARCH="armv7l"; QEMU_BIN=qemu-arm-static;;
    odroid-u2) _ARCH="armv7l"; QEMU_BIN=qemu-arm-static;;
    rpi) _ARCH="armv6l"; QEMU_BIN=qemu-arm-static;;
    *) die "$PROGNAME: invalid platform!";;
esac

if [ "$(id -u)" -ne 0 ]; then
    die "need root perms to continue, exiting."
fi

#
# Check for required binaries.
#
for f in chroot tar xbps-install xbps-reconfigure xbps-query; do
    if ! $f --version >/dev/null 2>&1; then
        die "$f binary is missing in your system, exiting."
    fi
done

#
# Check if package base-system is available.
#
rootfs=$(mktemp -d || die "FATAL: failed to create tempdir, exiting...")
mkdir -p $rootfs/var/db/xbps/keys
cp keys/*.plist $rootfs/var/db/xbps/keys

run_cmd_target "xbps-install -S $XBPS_CONFFILE $XBPS_CACHEDIR $XBPS_REPOSITORY -r $rootfs"
run_cmd_target "xbps-query -R -r $rootfs $XBPS_CONFFILE $XBPS_CACHEDIR $XBPS_REPOSITORY -ppkgver $PKGBASE"

chmod 755 $rootfs

PKGS="${PKGBASE} ${PLATFORM}-base"
[ -n "$EXTRA_PKGS" ] && PKGS="${PKGS} ${EXTRA_PKGS}"

mount_pseudofs
#
# Install base-system to the rootfs directory.
#
run_cmd_target "xbps-install -S $XBPS_CONFFILE $XBPS_CACHEDIR $XBPS_REPOSITORY -r $rootfs -y ${PKGS}"

# Enable en_US.UTF-8 locale and generate it into the target rootfs.
LOCALE=en_US.UTF-8
sed -e "s/\#\(${LOCALE}.*\)/\1/g" -i $rootfs/etc/default/libc-locales

#
# Reconfigure packages for target architecture: must be reconfigured
# thru the qemu user mode binary.
#
if [ -n "${_ARCH}" ]; then
    info_msg "Reconfiguring packages for ${_ARCH} ..."
    register_binfmt
    run_cmd "xbps-reconfigure -r $rootfs base-directories"
    run_cmd "chroot $rootfs xbps-reconfigure shadow"
    if [ "$PKGBASE" = "base-system-systemd" ]; then
        run_cmd "chroot $rootfs xbps-reconfigure systemd"
    fi
    run_cmd "chroot $rootfs xbps-reconfigure -a"
    rmdir $rootfs/usr/lib32
    rm -f $rootfs/lib32 $rootfs/lib64 $rootfs/usr/lib64
else
    if [ "$PKGBASE" = "base-system-systemd" ]; then
        run_cmd "chroot $rootfs xbps-reconfigure systemd"
    fi
fi

#
# Setup default root password.
#
run_cmd "chroot $rootfs sh -c 'echo "root:voidlinux" | chpasswd -c SHA512'"
umount_pseudofs
#
# Cleanup rootfs.
#
rm -f $rootfs/etc/.pwd.lock 2>/dev/null
rm -rf $rootfs/var/cache/* 2>/dev/null

#
# Generate final tarball.
#
arch=$ARCH
if [ -n "${_ARCH}" ]; then
    rm -f $rootfs/usr/bin/$QEMU_BIN
    arch=${_ARCH}
fi

tarball=void-${PLATFORM}-rootfs-$(date '+%Y%m%d').tar.xz

run_cmd "tar cp -C $rootfs . | xz -9 > $tarball"
rm -rf $rootfs

info_msg "Successfully created $tarball ($PLATFORM)"

# vim: set ts=4 sw=4 et:
