#!/bin/sh
#-
# Copyright (c) 2012-2014 Juan Romero Pardines <xtraeme@gmail.com>.
#               2012 Dave Elusive <davehome@redthumb.info.tm>.
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

# Make sure we don't inherit these from env.
SOURCE_DONE=
HOSTNAME_DONE=
KEYBOARD_DONE=
LOCALE_DONE=
TIMEZONE_DONE=
ROOTPASSWORD_DONE=
BOOTLOADER_DONE=
PARTITIONS_DONE=
NETWORK_DONE=
FILESYSTEMS_DONE=
USERNAME_DONE=
SYSTEMD_INIT=

TARGETDIR=/mnt/target
LOG=/dev/tty7
CONF_FILE=/tmp/.void-installer.conf
if [ ! -f $CONF_FILE ]; then
    touch -f $CONF_FILE
fi
ANSWER=$(mktemp -t vinstall-XXXXXXXX || exit 1)
TARGET_FSTAB=$(mktemp -t vinstall-fstab-XXXXXXXX || exit 1)

trap "DIE" INT TERM QUIT

# disable printk
if [ -w /proc/sys/kernel/printk ]; then
    echo 0 >/proc/sys/kernel/printk
fi

# Detect if this is an EFI system.
if [ -e /sys/firmware/efi/systab ]; then
    EFI_SYSTEM=1
fi

# Detect if systemd is installed
if [ "$(cat /proc/1/comm)" = "systemd" ]; then
    SYSTEMD_INIT=1
fi

# dialog colors
BLACK="\Z0"
RED="\Z1"
GREEN="\Z2"
YELLOW="\Z3"
BLUE="\Z4"
MAGENTA="\Z5"
CYAN="\Z6"
WHITE="\Z7"
BOLD="\Zb"
REVERSE="\Zr"
UNDERLINE="\Zu"
RESET="\Zn"

# Properties shared per widget.
MENULABEL="${BOLD}Use UP and DOWN keys to navigate \
menus. Use TAB to switch between buttons and ENTER to select.${RESET}"
MENUSIZE="14 60 0"
INPUTSIZE="8 60"
MSGBOXSIZE="8 70"
YESNOSIZE="$INPUTSIZE"
WIDGET_SIZE="10 70"

DIALOG() {
    rm -f $ANSWER
    dialog --colors --keep-tite --no-shadow --no-mouse \
        --backtitle "${BOLD}${WHITE}Void Linux installation -- http://www.voidlinux.eu/ (0.22 )${RESET}" \
        --cancel-label "Back" --aspect 20 "$@" 2>$ANSWER
    return $?
}

DIE() {
    rval=$1
    [ -z "$rval" ] && rval=0
    clear
    rm -f $ANSWER $TARGET_FSTAB
    # reenable printk
    if [ -w /proc/sys/kernel/printk ]; then
        echo 4 >/proc/sys/kernel/printk
    fi
    umount_filesystems
    exit $rval
}

set_option() {
    if grep -Eq "^${1}.*" $CONF_FILE; then
        sed -i -e "/^${1}.*/d" $CONF_FILE
    fi
    echo "${1} ${2}" >>$CONF_FILE
}

get_option() {
    echo $(grep -E "^${1}.*" $CONF_FILE|sed -e "s|${1}||")
}

show_disks() {
    local dev size sectorsize gbytes

    # IDE
    for dev in $(ls /sys/block|grep -E '^hd'); do
        if [ "$(cat /sys/block/$dev/device/media)" = "disk" ]; then
            # Find out nr sectors and bytes per sector;
            echo "/dev/$dev"
            size=$(cat /sys/block/$dev/size)
            sectorsize=$(cat /sys/block/$dev/queue/hw_sector_size)
            gbytes="$(($size * $sectorsize / 1024 / 1024 / 1024))"
            echo "size:${gbytes}GB;sector_size:$sectorsize"
        fi
    done
    # SATA/SCSI and Virtual disks (virtio)
    for dev in $(ls /sys/block|grep -E '^([sv]|xv)d'); do
        echo "/dev/$dev"
        size=$(cat /sys/block/$dev/size)
        sectorsize=$(cat /sys/block/$dev/queue/hw_sector_size)
        gbytes="$(($size * $sectorsize / 1024 / 1024 / 1024))"
        echo "size:${gbytes}GB;sector_size:$sectorsize"
    done
}

show_partitions() {
    local dev fstype fssize p part

    set -- $(show_disks)
    while [ $# -ne 0 ]; do
        disk=$(basename $1)
        shift 2
        # ATA/SCSI/SATA
        for p in /sys/block/$disk/$disk*; do
            if [ -d $p ]; then
                part=$(basename $p)
                fstype=$(lsblk -nfr /dev/$part|awk '{print $2}'|head -1)
                [ "$fstype" = "iso9660" ] && continue
                [ "$fstype" = "crypto_LUKS" ] && continue
                [ "$fstype" = "LVM2_member" ] && continue
                fssize=$(lsblk -nr /dev/$part|awk '{print $4}'|head -1)
                echo "/dev/$part"
                echo "size:${fssize:-unknown};fstype:${fstype:-none}"
            fi
        done
        # Software raid (md)
        for p in $(ls -d /dev/md* 2>/dev/null|grep '[0-9]'); do
            if cat /proc/mdstat|grep -qw $(echo $p|sed -e 's|/dev/||g'); then
                fstype=$(lsblk -nfr /dev/$part|awk '{print $2}')
                fssize=$(lsblk -nr /dev/$p|awk '{print $4}')
                echo "$p"
                echo "size:${fssize:-unknown};fstype:${fstype:-none}"
            fi
        done
        if [ ! -e /sbin/lvs ]; then
            continue
        fi
        # LVM
        lvs --noheadings|while read lvname vgname perms size; do
            echo "/dev/mapper/${vgname}-${lvname}"
            echo "size:${size};fstype:lvm"
        done
    done
}

menu_filesystems() {
    local dev fstype fssize mntpoint reformat

    while true; do
        DIALOG --title " Select the partition to edit " --menu "$MENULABEL" \
            ${MENUSIZE} $(show_partitions)
        [ $? -ne 0 ] && return

        dev=$(cat $ANSWER)
        DIALOG --title " Select the filesystem type for $dev " \
            --menu "$MENULABEL" ${MENUSIZE} \
            "btrfs" "Oracle's Btrfs" \
            "ext2" "Linux ext2 (no journaling)" \
            "ext3" "Linux ext3 (journal)" \
            "ext4" "Linux ext4 (journal)" \
            "f2fs" "Flash-Friendly Filesystem" \
            "swap" "Linux swap" \
            "vfat" "FAT32" \
            "xfs" "SGI's XFS"
        if [ $? -eq 0 ]; then
            fstype=$(cat $ANSWER)
        else
            continue
        fi
        if [ "$fstype" != "swap" ]; then
            DIALOG --inputbox "Please specify the mount point for $dev:" ${INPUTSIZE}
            if [ $? -eq 0 ]; then
                mntpoint=$(cat $ANSWER)
            elif [ $? -eq 1 ]; then
                continue
            fi
        else
            mntpoint=swap
        fi
        DIALOG --yesno "Do you want to create a new filesystem on $dev?" ${YESNOSIZE}
        if [ $? -eq 0 ]; then
            reformat=1
        elif [ $? -eq 1 ]; then
            reformat=0
        else
            continue
        fi
        fssize=$(lsblk -nr $dev|awk '{print $4}')
        set -- "$fstype" "$fssize" "$mntpoint" "$reformat"
        if [ -n "$1" -a -n "$2" -a -n "$3" -a -n "$4" ]; then
            local bdev=$(basename $dev)
            if grep -Eq "^MOUNTPOINT \/dev\/${bdev}.*" $CONF_FILE; then
                sed -i -e "/^MOUNTPOINT \/dev\/${bdev}.*/d" $CONF_FILE
            fi
            echo "MOUNTPOINT $dev $1 $2 $3 $4" >>$CONF_FILE
        fi
    done
}

menu_partitions() {
    DIALOG --title " Select the disk to partition " \
        --menu "$MENULABEL" ${MENUSIZE} $(show_disks)
    if [ $? -eq 0 ]; then
        local device=$(cat $ANSWER)

        DIALOG --title "Modify Partition Table on $device" --msgbox "\n
${BOLD}cfdisk will be executed in disk $device.${RESET}\n\n
For BIOS systems, MBR or GPT partition tables are supported.\n
To use GPT on PC BIOS systems an empty partition of 1MB must be added\n
at the first 2GB of the disk with the TOGGLE \`bios_grub' enabled.\n
${BOLD}NOTE: you don't need this on EFI systems.${RESET}\n\n
For EFI systems GPT is mandatory and a FAT32 partition with at least\n
100MB must be created with the TOGGLE \`boot', this will be used as\n
EFI System Partition. This partition must have mountpoint as \`/boot/efi'.\n\n
At least 2 partitions are required: swap and rootfs (/).\n
For swap, RAM*2 must be really enough. For / 600MB are required.\n\n
${BOLD}WARNING: /usr is not supported as a separate partition.${RESET}\n
${RESET}\n" 18 80
        if [ $? -eq 0 ]; then
            while true; do
                clear; cfdisk $device; PARTITIONS_DONE=1; partx -a $device; partx -u $device
                break
            done
        else
            return
        fi
    fi
}

menu_keymap() {
    if [ -n "$SYSTEMD_INIT" ]; then
        local _keymaps="$(localectl --no-pager list-keymaps)"
    else
        local _keymaps="$(find /usr/share/kbd/keymaps/ -type f -iname "*.map.gz" -printf "%f\n" | sed 's|.map.gz||g' | sort)"
    fi
    local _KEYMAPS=

    for f in ${_keymaps}; do
        _KEYMAPS="${_KEYMAPS} ${f} -"
    done
    while true; do
        DIALOG --title " Select your keymap " --menu "$MENULABEL" 14 70 14 ${_KEYMAPS}
        if [ $? -eq 0 ]; then
            set_option KEYMAP "$(cat $ANSWER)"
            loadkeys "$(cat $ANSWER)"
            KEYBOARD_DONE=1
            break
        else
            return
        fi
    done
}

set_keymap() {
    local KEYMAP=$(get_option KEYMAP)

    if [ -f /etc/vconsole.conf ]; then
        sed -i -e "s|KEYMAP=.*|KEYMAP=$KEYMAP|g" $TARGETDIR/etc/vconsole.conf
    else
        sed -i -e "s|KEYMAP=.*|KEYMAP=$KEYMAP|g" $TARGETDIR/etc/rc.conf
    fi
}

menu_locale() {
    local _locales="$(grep -E '\.UTF-8' /etc/default/libc-locales|awk '{print $1}'|sed -e 's/^#//')"
    local _LOCALES=

    for f in ${_locales}; do
        _LOCALES="${_LOCALES} ${f} -"
    done
    while true; do
        DIALOG --title " Select your locale " --menu "$MENULABEL" 14 70 14 ${_LOCALES}
        if [ $? -eq 0 ]; then
            set_option LOCALE "$(cat $ANSWER)"
            LOCALE_DONE=1
            break
        else
            return
        fi
    done
}

set_locale() {
    local LOCALE=$(get_option LOCALE)

    sed -i -e "s|LANG=.*|LANG=$LOCALE|g" $TARGETDIR/etc/locale.conf
    # Uncomment locale from /etc/default/libc-locales and regenerate it.
    sed -e "/${LOCALE}/s/^\#//" -i $TARGETDIR/etc/default/libc-locales
    echo "Running xbps-reconfigure -f glibc-locales ..." >$LOG
    chroot $TARGETDIR xbps-reconfigure -f glibc-locales >$LOG 2>&1
}

menu_timezone() {
    if [ -n "$SYSTEMD_INIT" ]; then
        local _tzones="$(timedatectl --no-pager list-timezones)"
    else
        local _tzones="$(cd /usr/share/zoneinfo; find Africa/ America/ Antarctica/ Arctic/ Asia/ Atlantic/ Australia/ Europe/ Indian/ Pacific/ -type f | sort)"
    fi
    local _TIMEZONES=

    for f in ${_tzones}; do
        _TIMEZONES="${_TIMEZONES} ${f} -"
    done
    while true; do
        DIALOG --title " Select your timezone " --menu "$MENULABEL" 14 70 14 ${_TIMEZONES}
        if [ $? -eq 0 ]; then
            set_option TIMEZONE "$(cat $ANSWER)"
            TIMEZONE_DONE=1
            break
        else
            return
        fi
    done
}

set_timezone() {
    local TIMEZONE="$(get_option TIMEZONE)"

    if [ -z "$SYSTEMD_INIT" ]; then
        sed -i -e "s|#TIMEZONE=.*|TIMEZONE=$TIMEZONE|g" $TARGETDIR/etc/rc.conf
    else
        ln -sf /usr/share/zoneinfo/${TIMEZONE} $TARGETDIR/etc/localtime
    fi
}

menu_hostname() {
    while true; do
        DIALOG --inputbox "Set the machine hostname:" ${INPUTSIZE}
        if [ $? -eq 0 ]; then
            set_option HOSTNAME "$(cat $ANSWER)"
            HOSTNAME_DONE=1
            break
        else
            return
        fi
    done
}

set_hostname() {
    echo $(get_option HOSTNAME) > $TARGETDIR/etc/hostname
}

menu_rootpassword() {
    local _firstpass= _secondpass= _desc=

    while true; do
        if [ -n "${_firstpass}" ]; then
            _desc="Enter the root password again (password won't be displayed)"
        else
            _desc="Enter the root password (password won't be displayed)"
        fi
        DIALOG --passwordbox "${_desc}" ${MSGBOXSIZE}
        if [ $? -eq 0 ]; then
            if [ -z "${_firstpass}" ]; then
                _firstpass="$(cat $ANSWER)"
            else
                _secondpass="$(cat $ANSWER)"
            fi
            if [ -n "${_firstpass}" -a -n "${_secondpass}" ]; then
                if [ "${_firstpass}" != "${_secondpass}" ]; then
                    DIALOG --infobox "Passwords do not match! please reenter it again" 6 80
                    unset _firstpass _secondpass
                    sleep 2 && continue
                fi
                set_option ROOTPASSWORD "${_firstpass}"
                ROOTPASSWORD_DONE=1
                break
            fi
        else
            return
        fi
    done
}

set_rootpassword() {
    echo "root:$(get_option ROOTPASSWORD)" | chpasswd -R $TARGETDIR -c SHA512
}

menu_bootloader() {
    while true; do
        DIALOG --title " Select the disk to install the bootloader" \
            --menu "$MENULABEL" ${MENUSIZE} $(show_disks)
        if [ $? -eq 0 ]; then
            set_option BOOTLOADER "$(cat $ANSWER)"
            BOOTLOADER_DONE=1
            break
        else
            return
        fi
    done
}

set_bootloader() {
    local dev=$(get_option BOOTLOADER) grub_args=

    # Check if it's an EFI system via efivars module.
    if [ -n "$EFI_SYSTEM" ]; then
        grub_args="--target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void_grub --recheck"
    fi
    echo "Running grub-install $grub_args $dev..." >$LOG
    chroot $TARGETDIR grub-install $grub_args $dev >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
        failed to install GRUB to $dev!\nCheck $LOG for errors." ${MSGBOXSIZE}
        DIE 1
    fi
    echo "Running grub-mkconfig on $TARGETDIR..." >$LOG
    chroot $TARGETDIR grub-mkconfig -o /boot/grub/grub.cfg >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR${RESET}: \
        failed to run grub-mkconfig!\nCheck $LOG for errors." ${MSGBOXSIZE}
        DIE 1
    fi
}

test_network() {
    rm -f xtraeme.asc && \
        xbps-uhelper fetch http://repo.voidlinux.eu/live/xtraeme.asc >$LOG 2>&1
    if [ $? -eq 0 ]; then
        DIALOG --msgbox "Network is working properly!" ${MSGBOXSIZE}
        NETWORK_DONE=1
        return 1
    fi
    DIALOG --msgbox "Network is unaccessible, please setup it properly." ${MSGBOXSIZE}
}

configure_wifi() {
    local dev="$1" ssid enc pass _wpasupconf=/etc/wpa_supplicant/wpa_supplicant.conf

    DIALOG --form "Wireless configuration for ${dev}\n(encryption type: wep or wpa)" 0 0 0 \
        "SSID:" 1 1 "" 1 16 30 0 \
        "Encryption:" 2 1 "" 2 16 3 0 \
        "Password:" 3 1 "" 3 16 30 0 || return 1
    set -- $(cat $ANSWER)
    ssid="$1"; enc="$2"; pass="$3";

    if [ -z "$ssid" ]; then
        DIALOG --msgbox "Invalid SSID." ${MSGBOXSIZE}
        return 1
    elif [ -z "$enc" -o "$enc" != "wep" -a "$enc" != "wpa" ]; then
        DIALOG --msgbox "Invalid encryption type (possible values: wep or wpa)." ${MSXBOXSIZE}
        return 1
    elif [ -z "$pass" ]; then
        DIALOG --msgbox "Invalid AP password." ${MSGBOXSIZE}
    fi

    rm -f ${_wpasupconf%.conf}-${dev}.conf
    cp -f ${_wpasupconf} ${_wpasupconf%.conf}-${dev}.conf
    if [ "$enc" = "wep" ]; then
        echo "network={" >> ${_wpasupconf%.conf}-${dev}.conf
        echo "  ssid=\"$ssid\"" >> ${_wpasupconf%.conf}-${dev}.conf
        echo "  wep_key0=\"$pass\"" >> ${_wpasupconf%.conf}-${dev}.conf
        echo "  wep_tx_keyidx=0" >> ${_wpasupconf%.conf}-${dev}.conf
        echo "  auth_alg=SHARED" >> ${_wpasupconf%.conf}-${dev}.conf
        echo "}" >> ${_wpasupconf%.conf}-${dev}.conf
    else
        wpa_passphrase "$ssid" "$pass" >> ${_wpasupconf%.conf}-${dev}.conf
    fi

    configure_net_dhcp $dev
    return $?
}

configure_net() {
    local dev="$1" rval

    DIALOG --yesno "Do you want to use DHCP for $dev?" ${YESNOSIZE}
    rval=$?
    if [ $rval -eq 0 ]; then
        configure_net_dhcp $dev
    elif [ $rval -eq 1 ]; then
        configure_net_static $dev
    fi
}

iface_setup() {
    ip addr show dev $1|grep -q 'inet '
    return $?
}

configure_net_dhcp() {
    local dev="$1"

    iface_setup $dev
    if [ $? -eq 1 ]; then
        dhcpcd -t 10 -w -4 -L $dev -e "wpa_supplicant_conf=/etc/wpa_supplicant/wpa_supplicant-${dev}.conf" 2>&1 | tee $LOG | \
            DIALOG --progressbox "Initializing $dev via DHCP..." ${WIDGET_SIZE}
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} failed to run dhcpcd. See $LOG for details." ${MSGBOXSIZE}
            return 1
        fi
        iface_setup $dev
        if [ $? -eq 1 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} DHCP request failed for $dev. Check $LOG for errors." ${MSGBOXSIZE}
            return 1
        fi
    fi
    test_network
    if [ $? -eq 1 ]; then
        set_option NETWORK "${dev} dhcp"
    fi
}

configure_net_static() {
    local ip gw dns1 dns2 dev=$1

    DIALOG --form "Static IP configuration for $dev:" 0 0 0 \
        "IP address:" 1 1 "192.168.0.2" 1 21 20 0 \
        "Gateway:" 2 1 "192.168.0.1" 2 21 20 0 \
        "DNS Primary" 3 1 "8.8.8.8" 3 21 20 0 \
        "DNS Secondary" 4 1 "8.8.4.4" 4 21 20 0 || return 1

    set -- $(cat $ANSWER)
    ip=$1; gw=$2; dns1=$3; dns2=$4
    echo "running: ip link set dev $dev up" >$LOG
    ip link set dev $dev up >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} Failed to bring $dev interface." ${MSGBOXSIZE}
        return 1
    fi
    echo "running: ip addr add $ip dev $dev"
    ip addr add $ip dev $dev >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} Failed to set ip to the $dev interface." ${MSGBOXSIZE}
        return 1
    fi
    ip route add $gw dev $dev >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} failed to setup your gateway." ${MSGBOXSIZE}
        return 1
    fi
    echo "nameserver $dns1" >/etc/resolv.conf
    echo "nameserver $dns2" >>/etc/resolv.conf
    test_network
    if [ $? -eq 1 ]; then
        set_option NETWORK "${dev} static $ip $gw $dns1 $dns2"
    fi
}

menu_network() {
    local dev addr f DEVICES

    for f in $(ls /sys/class/net); do
        [ "$f" = "lo" ] && continue
        addr=$(cat /sys/class/net/$f/address)
        DEVICES="$DEVICES $f $addr"
    done
    DIALOG --title " Select the network interface to configure " \
        --menu "$MENULABEL" ${MENUSIZE} ${DEVICES}
    if [ $? -eq 0 ]; then
        dev=$(cat $ANSWER)
        if $(echo $dev|egrep -q "^wl.*" 2>/dev/null); then
            configure_wifi $dev
        else
            configure_net $dev
        fi
    fi
}

validate_filesystems() {
    local mnts dev size fstype mntpt mkfs rootfound swapfound fmt
    local usrfound efi_system_partition

    unset TARGETFS
    mnts=$(grep -E '^MOUNTPOINT.*' $CONF_FILE)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        dev=$2; fstype=$3; size=$4; mntpt="$5"; mkfs=$6
        shift 6

        if [ "$mntpt" = "/" ]; then
            rootfound=1
        elif [ "$mntpt" = "/usr" ]; then
            usrfound=1
        elif [ "$fstype" = "vfat" -a "$mntpt" = "/boot/efi" ]; then
            efi_system_partition=1
        fi
        if [ "$mkfs" -eq 1 ]; then
            fmt="NEW FILESYSTEM: "
        fi
        if [ -z "$TARGETFS" ]; then
            TARGETFS="${fmt}$dev ($size) mounted on $mntpt as ${fstype}\n"
        else
            TARGETFS="${TARGETFS}${fmt}${dev} ($size) mounted on $mntpt as ${fstype}\n"
        fi
    done
    if [ -z "$rootfound" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
the mount point for the root filesystem (/) has not yet been configured." ${MSGBOXSIZE}
        return 1
    elif [ -n "$usrfound" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
/usr mount point has been configured but is not supported, please remove it to continue." ${MSGBOXSIZE}
        return 1
    elif [ -n "$EFI_SYSTEM" -a -z "$efi_system_partition" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
The EFI System Partition has not yet been configured, please create it\n
as FAT32, mountpoint /boot/efi and at least with 100MB of size." ${MSGBOXSIZE}
    fi
    FILESYSTEMS_DONE=1
}

create_filesystems() {
    local mnts dev mntpt fstype fspassno mkfs size rv uuid

    mnts=$(grep -E '^MOUNTPOINT.*' $CONF_FILE)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        dev=$2; fstype=$3; mntpt="$5"; mkfs=$6
        shift 6

        # swap partitions
        if [ "$fstype" = "swap" ]; then
            swapoff $dev >/dev/null 2>&1
            if [ "$mkfs" -eq 1 ]; then
                mkswap $dev >$LOG 2>&1
                if [ $? -ne 0 ]; then
                    DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to create swap on ${dev}!\ncheck $LOG for errors." ${MSGBOXSIZE}
                    DIE 1
                fi
            fi
            swapon $dev >$LOG 2>&1
            if [ $? -ne 0 ]; then
                DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to activate swap on $dev!\ncheck $LOG for errors." ${MSGBOXSIZE}
                DIE 1
            fi
            # Add entry for target fstab
            uuid=$(blkid -o value -s UUID "$dev")
            echo "UUID=$uuid none swap sw 0 0" >>$TARGET_FSTAB
            continue
        fi

        if [ "$mkfs" -eq 1 ]; then
            case "$fstype" in
            btrfs) MKFS="mkfs.btrfs -f"; modprobe btrfs >$LOG 2>&1;;
            ext2) MKFS="mke2fs -F"; modprobe ext2 >$LOG 2>&1;;
            ext3) MKFS="mke2fs -F -j"; modprobe ext3 >$LOG 2>&1;;
            ext4) MKFS="mke2fs -F -t ext4"; modprobe ext4 >$LOG 2>&1;;
            f2fs) MKFS="mkfs.f2fs"; modprobe f2fs >$LOG 2>&1;;
            vfat) MKFS="mkfs.vfat -F32"; modprobe vfat >$LOG 2>&1;;
            xfs) MKFS="mkfs.xfs -f"; modprobe xfs >$LOG 2>&1;;
            esac
            DIALOG --infobox "Creating filesystem $fstype on $dev for $mntpt ..." 8 60
            echo "Running $MKFS $dev..." >$LOG
            $MKFS $dev >$LOG 2>&1; rv=$?
            if [ $rv -ne 0 ]; then
                DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to create filesystem $fstype on $dev!\ncheck $LOG for errors." ${MSGBOXSIZE}
                DIE 1
            fi
        fi
        # Mount rootfs the first one.
        [ "$mntpt" != "/" ] && continue
        mkdir -p $TARGETDIR
        echo "Mounting $dev on $mntpt ($fstype)..." >$LOG
        mount -t $fstype $dev $TARGETDIR >$LOG 2>&1
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to mount $dev on ${mntpt}! check $LOG for errors." ${MSGBOXSIZE}
            DIE 1
        fi
        # Add entry to target fstab
        uuid=$(blkid -o value -s UUID "$dev")
        if [ "$fstype" = "f2fs" ]; then
            fspassno=0
        else
            fspassno=1
        fi
        echo "UUID=$uuid $mntpt $fstype defaults 0 $fspassno" >>$TARGET_FSTAB
    done

    # mount all filesystems in target rootfs
    mnts=$(grep -E '^MOUNTPOINT.*' $CONF_FILE)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        dev=$2; fstype=$3; mntpt="$5"
        shift 6
        [ "$mntpt" = "/" -o "$fstype" = "swap" ] && continue
        mkdir -p ${TARGETDIR}${mntpt}
        echo "Mounting $dev on $mntpt ($fstype)..." >$LOG
        mount -t $fstype $dev ${TARGETDIR}${mntpt} >$LOG 2>&1
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to mount $dev on $mntpt! check $LOG for errors." ${MSGBOXSIZE}
            DIE
        fi
        # Add entry to target fstab
        uuid=$(blkid -o value -s UUID "$dev")
        echo "UUID=$uuid $mntpt $fstype defaults 0 2" >>$TARGET_FSTAB
    done
}

mount_filesystems() {
    for f in sys proc dev; do
        [ ! -d $TARGETDIR/$f ] && mkdir $TARGETDIR/$f
        echo "Mounting $TARGETDIR/$f..." >$LOG
        mount --bind /$f $TARGETDIR/$f >$LOG 2>&1
    done
}

umount_filesystems() {
    local f

    for f in sys/fs/fuse/connections sys proc dev; do
        echo "Unmounting $TARGETDIR/$f..." >$LOG
        umount $TARGETDIR/$f >$LOG 2>&1
    done
    local mnts="$(grep -E '^MOUNTPOINT.*$' $CONF_FILE)"
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        local dev=$2; local fstype=$3; local mntpt=$5
        shift 6
        if [ "$fstype" = "swap" ]; then
            echo "Disabling swap space on $dev..." >$LOG
            swapoff $dev >$LOG 2>&1
            continue
        fi
        if [ "$mntpt" != "/" ]; then
            echo "Unmounting $TARGETDIR/$mntpt..." >$LOG
            umount $TARGETDIR/$mntpt >$LOG 2>&1
        fi
    done
    echo "Unmounting $TARGETDIR..." >$LOG
    umount $TARGETDIR >$LOG 2>&1
}

copy_rootfs() {
    DIALOG --title "Check /dev/tty7 for details" \
        --infobox "Copying live image to target rootfs, please wait ..." 4 60
    LANG=C cp -axvnu / $TARGETDIR >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIE 1
    fi
}

install_packages() {
    local _grub= _syspkg=

    if [ -n "$EFI_SYSTEM" ]; then
        _grub="grub-x86_64-efi"
    else
        _grub="grub"
    fi

    _syspkg="base-system"

    mkdir -p $TARGETDIR/var/db/xbps/keys $TARGETDIR/usr/share/xbps
    cp -a /usr/share/xbps/repo.d $TARGETDIR/usr/share/xbps/
    cp /var/db/xbps/keys/*.plist $TARGETDIR/var/db/xbps/keys
    mkdir -p $TARGETDIR/boot/grub
    stdbuf -oL xbps-install  -r $TARGETDIR -Sy ${_syspkg} ${_grub} 2>&1 | \
        DIALOG --title "Installing base system packages..." \
        --programbox 24 80
    if [ $? -ne 0 ]; then
        DIE 1
    fi
}

enable_dhcpd() {
    if [ -n "$SYSTEMD_INIT" ]; then
        chroot $TARGETDIR systemctl enable dhcpcd.service >$LOG 2>&1
    else
        ln -s /etc/sv/dhcpcd $TARGETDIR/etc/runit/runsvdir/default/dhcpcd
    fi
}

menu_install() {
    # Don't continue if filesystems are not ready.
    validate_filesystems || return 1

    ROOTPASSWORD_DONE="$(get_option ROOTPASSWORD)"
    BOOTLOADER_DONE="$(get_option BOOTLOADER)"

    if [ -z "$FILESYSTEMS_DONE" ]; then
        DIALOG --msgbox "${BOLD}Required filesystems were not configured, \
please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    elif [ -z "$ROOTPASSWORD_DONE" ]; then
        DIALOG --msgbox "${BOLD}The root password has not been configured, \
please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    elif [ -z "$BOOTLOADER_DONE" ]; then
        DIALOG --msgbox "${BOLD}The disk to install the bootloader has not been \
configured, please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    fi

    DIALOG --yesno "${BOLD}The following operations will be executed:${RESET}\n\n
${BOLD}${TARGETFS}${RESET}\n
${BOLD}${RED}WARNING: data on partitions will be COMPLETELY DESTROYED for new \
filesystems.${RESET}\n\n
${BOLD}Do you want to continue?${RESET}" 20 80 || return
    unset TARGETFS

    # Create and mount filesystems
    create_filesystems

    # If source not set use defaults.
    if [ "$(get_option SOURCE)" = "local" -o -z "$SOURCE_DONE" ]; then
        copy_rootfs
        . /etc/default/live.conf
        rm -f $TARGETDIR/etc/motd
        rm -f $TARGETDIR/etc/issue
        # Remove live user.
        echo "Removing $USERNAME live user from targetdir ..." >$LOG
        chroot $TARGETDIR userdel -r $USERNAME >$LOG 2>&1
        DIALOG --title "Check /dev/tty7 for details" \
            --infobox "Rebuilding initramfs for target ..." 4 60
        echo "Rebuilding initramfs for target ..." >$LOG
        chroot $TARGETDIR dracut --force >>$LOG 2>&1
        DIALOG --title "Check /dev/tty7 for details" \
            --infobox "Removing temporary packages from target ..." 4 60
        echo "Removing temporary packages from target ..." >$LOG
        xbps-remove -r $TARGETDIR -Ry dialog >>$LOG 2>&1
        rmdir $TARGETDIR/mnt/target
        # mount required fs
        mount_filesystems
    else
        # mount required fs
        mount_filesystems
        # network install, use packages.
        install_packages
    fi

    DIALOG --infobox "Applying installer settings..." 4 60

    # copy target fstab.
    install -Dm644 $TARGET_FSTAB $TARGETDIR/etc/fstab
    # Mount /tmp as tmpfs.
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" >> $TARGETDIR/etc/fstab


    # set up keymap, locale, timezone, hostname and root passwd.
    set_keymap
    set_locale
    set_timezone
    set_hostname
    set_rootpassword

    # Copy /etc/skel files for root.
    cp $TARGETDIR/etc/skel/.[bix]* $TARGETDIR/root

    # network settings for target
    if [ -n "$NETWORK_DONE" ]; then
        local net="$(get_option NETWORK)"
        set -- ${net}
        local _dev="$1" _type="$2" _ip="$3" _gw="$4" _dns1="$5" _dns2="$6"
        if [ -z "$_type" ]; then
            # network type empty??!!!
            :
        elif [ "$_type" = "dhcp" ]; then
            if [ -f /etc/wpa_supplicant/wpa_supplicant-${_dev}.conf ]; then
                cp /etc/wpa_supplicant/wpa_supplicant-${_dev}.conf $TARGETDIR/etc/wpa_supplicant
                if [ -n "$SYSTEMD_INIT" ]; then
                    chroot $TARGETDIR systemctl enable dhcpcd@${_dev}.service >$LOG 2>&1
                else
                    ln -s /etc/sv/dhcpcd-${_dev} $TARGETDIR/etc/runit/runsvdir/default/dhcpcd-${_dev}
                fi
            else
                enable_dhcpd
            fi
        elif [ -n "$dev" -a -n "$type" = "static" ]; then
            # static IP through dhcpcd.
            mv $TARGETDIR/etc/dhcpcd.conf $TARGETDIR/etc/dhdpcd.conf.orig
            echo "# Static IP configuration set by the void-installer for $_dev." \
                >$TARGETDIR/etc/dhcpcd.conf
            echo "interface $_dev" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static ip_address=$_ip" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static routers=$_gw" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static domain_name_servers=$_dns1 $_dns2" >>$TARGETDIR/etc/dhcpcd.conf
            enable_dhcpd
        fi
    fi

    # install bootloader.
    set_bootloader
    sync && sync && sync

    # unmount all filesystems.
    umount_filesystems

    # installed successfully.
    DIALOG --yesno "${BOLD}Void Linux has been installed successfully!${RESET}\n
Do you want to reboot the system?" ${YESNOSIZE}
    if [ $? -eq 0 ]; then
        shutdown -r now
    else
        return
    fi
}

menu_source() {
    local src=

    DIALOG --title " Select installation source " \
        --menu "$MENULABEL" 8 70 0 \
        "Local" "Packages from ISO image" \
        "Network" "Packages from official remote reposity"
    case "$(cat $ANSWER)" in
        "Local") src="local";;
        "Network") src="net"; menu_network;;
        *) return 1;;
    esac
    SOURCE_DONE=1
    set_option SOURCE $src
}

menu_username() {
	 xbps-uchroot /bin/bash /usr/bin/mvuser
}

menu() {
    if [ -z "$DEFITEM" ]; then
        DEFITEM="Keyboard"
    fi

    DIALOG --default-item $DEFITEM \
        --extra-button --extra-label "Settings" \
        --title " Void Linux installation menu " \
        --menu "$MENULABEL" 10 70 0 \
        "Keyboard" "Set system keyboard" \
        "Network" "Set up the network" \
        "Source" "Set source installation" \
        "Hostname" "Set system hostname" \
        "Locale" "Set system locale" \
        "Timezone" "Set system time zone" \
        "RootPassword" "Set system root password" \
        "BootLoader" "Set disk to install bootloader" \
        "Partition" "Partition disk(s)" \
        "Filesystems" "Configure filesystems and mount points" \
        "Install" "Start installation with saved settings" \
		"Username" "Change username and config files to suit" \ 
        "Exit" "Exit installation"

    if [ $? -eq 3 ]; then
        # Show settings
        cp $CONF_FILE /tmp/conf_hidden.$$;
        sed -i "s/^ROOTPASSWORD.*/ROOTPASSWORD <-hidden->/" /tmp/conf_hidden.$$
        DIALOG --title "Saved settings for installation" --textbox /tmp/conf_hidden.$$ 14 60
        rm /tmp/conf_hidden.$$
        return
    fi

    case $(cat $ANSWER) in
        "Keyboard") menu_keymap && [ -n "$KEYBOARD_DONE" ] && DEFITEM="Network";;
        "Network") menu_network && [ -n "$NETWORK_DONE" ] && DEFITEM="Source";;
        "Source") menu_source && [ -n "$SOURCE_DONE" ] && DEFITEM="Hostname";;
        "Hostname") menu_hostname && [ -n "$HOSTNAME_DONE" ] && DEFITEM="Locale";;
        "Locale") menu_locale && [ -n "$LOCALE_DONE" ] && DEFITEM="Timezone";;
        "Timezone") menu_timezone && [ -n "$TIMEZONE_DONE" ] && DEFITEM="RootPassword";;
        "RootPassword") menu_rootpassword && [ -n "$ROOTPASSWORD_DONE" ] && DEFITEM="BootLoader";;
        "BootLoader") menu_bootloader && [ -n "$BOOTLOADER_DONE" ] && DEFITEM="Partition";;
        "Partition") menu_partitions && [ -n "$PARTITIONS_DONE" ] && DEFITEM="Filesystems";;
        "Filesystems") menu_filesystems && [ -n "$FILESYSTEMS_DONE" ] && DEFITEM="Install";;
		"Username") menu_username && [ -n "$USERNAME_DONE" ] && DEFITEM="Filesystems";;
        "Install") menu_install;;
        "Exit") DIE;;
        *) DIALOG --yesno "Abort Installation?" ${YESNOSIZE} && DIE
    esac
}

if [ ! -x /bin/dialog ]; then
    echo "ERROR: missing dialog command, exiting..."
    exit 1
fi
#
# main()
#
DIALOG --title "${BOLD}${RED} Enter the void ... ${RESET}" --msgbox "\n
Welcome to the Void Linux installation. A simple and minimal \
Linux distribution made from scratch and built from the source package tree \
available for XBPS, a new alternative binary package system.\n\n
The installation should be pretty straightforward, if you are in trouble \
please join us at ${BOLD}#xbps on irc.freenode.org${RESET}.\n\n
${BOLD}http://www.voidlinux.eu${RESET}\n\n" 16 80

while true; do
    menu
done

exit 0
# vim: set ts=4 sw=4 et:
