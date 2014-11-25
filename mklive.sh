#!/bin/bash
#
# vim: set ts=4 sw=4 et:
#
#-
# Copyright (c) 2009-2014 Juan Romero Pardines.
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
set -E
trap "echo; error_out $LINENO $?" INT TERM HUP ERR

readonly REQUIRED_PKGS="base-files syslinux grub-x86_64-efi squashfs-tools xorriso"
readonly PROGNAME=$(basename $0)

script_path=$(readlink -f ${0%/*})

info_msg() {
    printf "\033[1m$@\n\033[m"
}

error_out() {
    info_msg "There was an error in line $1 ... cleaning up $BUILDDIR, exiting."

#    [ -d "$BUILDDIR" ] && rm -rf "$BUILDDIR"

    exit 1
}

usage() {
    cat <<_EOF
Usage: $(basename $0) [options]

Options:
 -a <xbps-arch>     Set XBPS_ARCH (do not use it unless you know what it is)
 -b <system-pkg>    Set an alternative base-system package (defaults to base-system).
 -r <repo-url>      Use this XBPS repository (may be specified multiple times).
 -c <cachedir>      Use this XBPS cache directory (/var/cache/xbps if unset).
 -k <keymap>        Default keymap to use (us if unset)
 -l <locale>        Default locale to use (en_US.UTF-8 if unset).
 -i <lz4|gzip|bzip2|xz> Compression type for the initramfs image (lz4 if unset).
 -s <gzip|bzip2|xz>     Compression type for the squashfs image (xz if unset)
 -S <freesize>      Allocate this free size (MB) for the rootfs.
 -o <file>          Output file name for the ISO image (auto if unset).
 -p "pkg pkgN ..."  Install additional packages into the ISO image.
					Script will auto load any packages it finds in a file called packages (local directory).

 -C "cmdline args"  Add additional kernel command line arguments.
 -T "title"         Modify the bootloader title.

The $(basename $0) script generates a live image of the Void Linux distribution.
This ISO image can be written to a CD/DVD-ROM or any USB stick.
_EOF
    exit 1
}

copy_void_keys() {
    mkdir -p "$1"/var/db/xbps/keys
    cp keys/*.plist "$1"/var/db/xbps/keys
}
copy_void_conf() {
    install -Dm644 data/void-vpkgs.conf "$1"/usr/share/xbps/virtualpkg.d/void.conf
}

install_prereqs() {
    copy_void_conf $VOIDHOSTDIR
    $XBPS_INSTALL_CMD -r $VOIDHOSTDIR $XBPS_REPOSITORY $XBPS_CACHEDIR -y ${REQUIRED_PKGS} >> $LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        info_msg "Failed to install required software, exiting..."
        error_out
    fi
}

install_packages() {
    if [ -n "$BASE_ARCH" ]; then
        export XBPS_ARCH="$BASE_ARCH"
    fi
    copy_void_conf $ROOTFS
    # Check that all pkgs are reachable.
    ${XBPS_INSTALL_CMD} -r $ROOTFS $XBPS_REPOSITORY $XBPS_CACHEDIR -yn ${PACKAGE_LIST} >>$LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        info_msg "Missing required binary packages, exiting..."
        error_out
    fi

    ${XBPS_INSTALL_CMD} -r $ROOTFS $XBPS_REPOSITORY $XBPS_CACHEDIR -y ${PACKAGE_LIST} >>$LOGFILE 2>&1
    ${XBPS_INSTALL_CMD} -r $ROOTFS $XBPS_REPOSITORY $XBPS_CACHEDIR  -yu >>$LOGFILE 2>&1
    ${XBPS_REMOVE_CMD} -r $ROOTFS $XBPS_CACHEDIR -o >>$LOGFILE 2>&1

    # Enable choosen UTF-8 locale and generate it into the target rootfs.
    if [ -f $ROOTFS/etc/default/libc-locales ]; then
        sed -e "s/\#\(${LOCALE}.*\)/\1/g" -i $ROOTFS/etc/default/libc-locales
        xbps-uchroot $ROOTFS xbps-reconfigure -f glibc-locales >>$LOGFILE 2>&1
    fi

    if [ -x installer.sh ]; then
        install -Dm755 installer.sh $ROOTFS/usr/sbin/void-installer
    else
        install -Dm755 /usr/sbin/void-installer $ROOTFS/usr/sbin/void-installer
    fi
    # Cleanup and remove useless stuff.
    rm -rf $ROOTFS/var/cache/* $ROOTFS/run/* $ROOTFS/var/run/*

    unset XBPS_ARCH
}

copy_dracut_files() {
    mkdir -p $1/usr/lib/dracut/modules.d/01vmklive
    cp dracut/*.sh $1/usr/lib/dracut/modules.d/01vmklive/
}

generate_initramfs() {
    # Install required pkgs in a temporary rootdir to create
    # the initramfs and to copy required files.
    copy_dracut_files $VOIDHOSTDIR
    copy_void_conf $VOIDHOSTDIR
    $XBPS_INSTALL_CMD -r $VOIDHOSTDIR $XBPS_REPOSITORY $XBPS_CACHEDIR -y base-system xz lz4 >>$LOGFILE 2>&1

    if [ "$BASE_SYSTEM_PKG" = "base-system-systemd" ]; then
        _args="--add systemd"
    else
        _args="--omit systemd"
    fi
    xbps-uchroot $VOIDHOSTDIR /usr/bin/dracut --${INITRAMFS_COMPRESSION} \
        --force-add "vmklive" ${_args} "/boot/initrd" $KERNELVERSION >>$LOGFILE 2>&1

    mv $VOIDHOSTDIR/boot/initrd $BOOT_DIR
    cp $VOIDHOSTDIR/boot/vmlinuz-$KERNELVERSION $BOOT_DIR/vmlinuz
}

generate_isolinux_boot() {
    cp -f $SYSLINUX_DATADIR/isolinux.bin "$ISOLINUX_DIR"
    cp -f $SYSLINUX_DATADIR/ldlinux.c32 "$ISOLINUX_DIR"
    cp -f $SYSLINUX_DATADIR/libcom32.c32 "$ISOLINUX_DIR"
    cp -f $SYSLINUX_DATADIR/vesamenu.c32 "$ISOLINUX_DIR"
    cp -f $SYSLINUX_DATADIR/libutil.c32 "$ISOLINUX_DIR"
    cp -f $SYSLINUX_DATADIR/chain.c32 "$ISOLINUX_DIR"
    cp -f isolinux/isolinux.cfg.in "$ISOLINUX_DIR"/isolinux.cfg
    cp -f ${SPLASH_IMAGE} "$ISOLINUX_DIR"

    sed -i  -e "s|@@SPLASHIMAGE@@|$(basename ${SPLASH_IMAGE})|" \
        -e "s|@@KERNVER@@|${KERNELVERSION}|" \
        -e "s|@@KEYMAP@@|${KEYMAP}|" \
        -e "s|@@ARCH@@|$(uname -m)|" \
        -e "s|@@LOCALE@@|${LOCALE}|" \
        -e "s|@@BOOT_TITLE@@|${BOOT_TITLE}|" \
        -e "s|@@BOOT_CMDLINE@@|${BOOT_CMDLINE}|" \
        $ISOLINUX_DIR/isolinux.cfg
}

generate_grub_efi_boot() {
    cp -f grub/grub.cfg $GRUB_DIR
    cp -f grub/grub_void.cfg.in $GRUB_DIR/grub_void.cfg
    sed -i  -e "s|@@SPLASHIMAGE@@|$(basename ${SPLASH_IMAGE})|" \
        -e "s|@@KERNVER@@|${KERNELVERSION}|" \
        -e "s|@@KEYMAP@@|${KEYMAP}|" \
        -e "s|@@ARCH@@|$(uname -m)|" \
        -e "s|@@BOOT_TITLE@@|${BOOT_TITLE}|" \
        -e "s|@@BOOT_CMDLINE@@|${BOOT_CMDLINE}|" \
        -e "s|@@LOCALE@@|${LOCALE}|" $GRUB_DIR/grub_void.cfg

    modprobe -q loop

    # Create EFI vfat image.
    dd if=/dev/zero of=$GRUB_DIR/efiboot.img bs=1024 count=4096  >>$LOGFILE 2>&1
    mkfs.vfat -F12 -S 512 -n "grub_uefi" "$GRUB_DIR/efiboot.img" >>$LOGFILE 2>&1

    GRUB_EFI_TMPDIR="$(mktemp --tmpdir=$HOME -d)"
    LOOP_DEVICE="$(losetup --show --find ${GRUB_DIR}/efiboot.img)"
    mount -o rw,flush -t vfat "${LOOP_DEVICE}" "${GRUB_EFI_TMPDIR}" >>$LOGFILE 2>&1

    cp -a $IMAGEDIR/boot $VOIDHOSTDIR
    xbps-uchroot $VOIDHOSTDIR grub-mkstandalone --directory="/usr/lib/grub/x86_64-efi" \
        --format="x86_64-efi" \
        --compression="xz" --output="/tmp/bootx64.efi" \
        "boot/grub/grub.cfg" >>$LOGFILE 2>&1
    mkdir -p ${GRUB_EFI_TMPDIR}/EFI/boot
    cp -f $VOIDHOSTDIR/tmp/bootx64.efi ${GRUB_EFI_TMPDIR}/EFI/boot/
    umount "$GRUB_EFI_TMPDIR"
    losetup --detach "${LOOP_DEVICE}"
    rm -rf $GRUB_EFI_TMPDIR
}

generate_squashfs() {
    # Find out required size for the rootfs and create an ext3fs image off it.
    ROOTFS_SIZE=$(du -sm "$ROOTFS"|awk '{print $1}')
    if [ -z "$ROOTFS_FREESIZE" ]; then
        ROOTFS_FREESIZE="$((ROOTFS_SIZE/6))"
    fi
    mkdir -p "$BUILDDIR/tmp/LiveOS"
    dd if=/dev/zero of="$BUILDDIR/tmp/LiveOS/ext3fs.img" \
        bs="$((ROOTFS_SIZE+ROOTFS_FREESIZE))M" count=1 >>$LOGFILE 2>&1
    mkdir -p "$BUILDDIR/tmp-rootfs"
    mkfs.ext3 -F -m1 "$BUILDDIR/tmp/LiveOS/ext3fs.img" >>$LOGFILE 2>&1
    mount -o loop "$BUILDDIR/tmp/LiveOS/ext3fs.img" "$BUILDDIR/tmp-rootfs"
    cp -a $ROOTFS/* $BUILDDIR/tmp-rootfs/
    umount -f "$BUILDDIR/tmp-rootfs"
    mkdir -p "$IMAGEDIR/LiveOS"

    mksquashfs "$BUILDDIR/tmp" "$IMAGEDIR/LiveOS/squashfs.img" \
        -comp ${SQUASHFS_COMPRESSION} >>$LOGFILE 2>&1
    chmod 444 "$IMAGEDIR/LiveOS/squashfs.img"
    # Remove rootfs and temporary dirs, we don't need them anymore.
    rm -rf "$ROOTFS" "$BUILDDIR/tmp-rootfs" "$BUILDDIR/tmp"
}

generate_iso_image() {
    xorriso -as mkisofs \
        -iso-level 3 -rock -joliet \
        -max-iso9660-filenames -omit-period \
        -omit-version-number -relaxed-filenames -allow-lowercase \
        -volid "VOID_LIVE" \
        -eltorito-boot boot/isolinux/isolinux.bin \
        -eltorito-catalog boot/isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e boot/grub/efiboot.img -isohybrid-gpt-basdat -no-emul-boot \
        -isohybrid-mbr $SYSLINUX_DATADIR/isohdpfx.bin \
        -output "$CURDIR/$OUTPUT_FILE" "$IMAGEDIR" >>$LOGFILE 2>&1
}

#
# main()
#
while getopts "a:b:r:c:C:T:k:l:i:s:S:o:p:h" opt; do
    case $opt in
        a) BASE_ARCH="$OPTARG";;
        b) BASE_SYSTEM_PKG="$OPTARG";;
        r) XBPS_REPOSITORY+="--repository=$OPTARG ";;
        c) XBPS_CACHEDIR="--cachedir=$OPTARG";;
        k) KEYMAP="$OPTARG";;
        l) LOCALE="$OPTARG";;
        i) INITRAMFS_COMPRESSION="$OPTARG";;
        s) SQUASHFS_COMPRESSION="$OPTARG";;
        S) ROOTFS_FREESIZE="$OPTARG";;
        o) OUTPUT_FILE="$OPTARG";;
        p) PACKAGE_LIST="$OPTARG";;
        C) BOOT_CMDLINE="$OPTARG";;
        T) BOOT_TITLE="$OPTARG";;
        h) usage;;
    esac
done
shift $(($OPTIND - 1))

# Set defaults
: ${XBPS_CACHEDIR:=--cachedir=/var/cache/xbps}
: ${KEYMAP:=us}
: ${LOCALE:=en_US.UTF-8}
: ${INITRAMFS_COMPRESSION:=xz}
: ${SQUASHFS_COMPRESSION:=xz}
: ${BASE_SYSTEM_PKG:=base-system}
: ${BOOT_TITLE:="Void Linux"}

# Required packages in the image for a working system.
PACKAGE_LIST="$BASE_SYSTEM_PKG $PACKAGE_LIST"
if [ -f ${script_path}/packages ]; then
	PACKAGE_LIST="$PACKAGE_LIST $(grep -h -v ^# ${script_path}/packages)"
fi
LOGFILE="$(mktemp -t vmklive-XXXXXXXXXX.log)"

# Check for root permissions.
if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root, exiting..."
    exit 1
fi

readonly CURDIR="$PWD"

ISO_VOLUME="VOID_LIVE"
if [ -n "$ROOTDIR" ]; then
    BUILDDIR=$(mktemp --tmpdir="$ROOTDIR" -d)
else
    BUILDDIR=$(mktemp --tmpdir="$(pwd -P)" -d)
fi
BUILDDIR=$(readlink -f $BUILDDIR)
IMAGEDIR="$BUILDDIR/image"
ROOTFS="$IMAGEDIR/rootfs"
echo $ROOTFS
VOIDHOSTDIR="$BUILDDIR/void-host"
echo $VOIDHOSTDIR
BOOT_DIR="$IMAGEDIR/boot"
ISOLINUX_DIR="$BOOT_DIR/isolinux"
GRUB_DIR="$BOOT_DIR/grub"
ISOLINUX_CFG="$ISOLINUX_DIR/isolinux.cfg"

: ${XBPS_REPOSITORY:=--repository=http://repo.voidlinux.eu/current}
: ${SYSLINUX_DATADIR:=$VOIDHOSTDIR/usr/share/syslinux}
: ${SPLASH_IMAGE:=data/splash.png}
: ${XBPS_INSTALL_CMD:=xbps-install}
: ${XBPS_REMOVE_CMD:=xbps-remove}
: ${XBPS_QUERY_CMD:=xbps-query}
: ${XBPS_RINDEX_CMD:=xbps-rindex}
: ${XBPS_UHELPER_CMD:=xbps-uhelper}
: ${XBPS_RECONFIGURE_CMD:=xbps-reconfigure}

mkdir -p $ROOTFS $VOIDHOSTDIR $ISOLINUX_DIR $GRUB_DIR

info_msg "Redirecting stdout/stderr to $LOGFILE ..."
info_msg "[1/9] Synchronizing XBPS repository data..."
# Sync index for remote repos first.
copy_void_keys $ROOTFS
$XBPS_INSTALL_CMD -r $ROOTFS ${XBPS_REPOSITORY} -S
cp -r $ROOTFS/* $VOIDHOSTDIR


_linux_series=$($XBPS_QUERY_CMD -r $ROOTFS ${XBPS_REPOSITORY:=-R} -x linux)
KERNELVERSION=$($XBPS_QUERY_CMD -r $ROOTFS ${XBPS_REPOSITORY:=-R} -p pkgver ${_linux_series})
KERNELVERSION=$($XBPS_UHELPER_CMD getpkgversion $KERNELVERSION)

: ${OUTPUT_FILE="voidbang-$(uname -m)-${KERNELVERSION}-$(date +%d%m%Y).iso"}

#
# Install required packages to generate the image.
#
info_msg "[2/9] Installing software to generate the image: ${REQUIRED_PKGS} ..."
install_prereqs

#
# Install live system and specified packages.
#
mkdir -p "$ROOTFS"/etc
[ -s data/motd ] && cp data/motd $ROOTFS/etc
[ -s data/issue ] && cp data/issue $ROOTFS/etc

info_msg "[3/9] Installing void pkgs into the rootfs: ${PACKAGE_LIST} ..."
install_packages

#
# VoidBang magic starts here
#
# copy overlay here to $ROOTFS need script path and change owner
cp -a /home/mrgreen/voidbang/overlay/* "$ROOTFS"
# change owner of overlay files
find $ROOTFS -user mrgreen -exec chown root:root {} \;
# run customroot script to start services live...
xbps-uchroot $ROOTFS /bin/bash /root/customroot
# remove once complete
rm $ROOTFS/root/customroot


export PATH=$VOIDHOSTDIR/usr/bin:$VOIDHOSTDIR/usr/sbin:$PATH
export LD_LIBRARY_PATH=$VOIDHOSTDIR/usr/lib
#
# Generate the initramfs.
#
info_msg "[4/9] Generating initramfs image ($INITRAMFS_COMPRESSION)..."
generate_initramfs

#
# Generate the isolinux boot.
#
info_msg "[5/9] Generating isolinux support for PC-BIOS systems..."
generate_isolinux_boot

#
# Generate the GRUB EFI boot.
#
info_msg "[6/9] Generating GRUB support for EFI systems..."
generate_grub_efi_boot

#
# Generate the squashfs image from rootfs.
#
info_msg "[7/9] Generating squashfs image ($SQUASHFS_COMPRESSION) from rootfs..."
generate_squashfs

#
# Generate the ISO image.
#
info_msg "[8/9] Generating ISO image..."
generate_iso_image

info_msg "[9/9] Removing build directory..."
#rm -rf "$BUILDDIR"

hsize=$(du -sh "$CURDIR/$OUTPUT_FILE"|awk '{print $1}')
info_msg "Created $(readlink -f $CURDIR/$OUTPUT_FILE) ($hsize) successfully."

exit 0
