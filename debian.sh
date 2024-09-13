#!/usr/bin/env bash
set -euo pipefail

RELEASE=bookworm
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

HOSTNAME="debian"
KEYMAP="us"
LOCALE="C.UTF-8"
TIMEZONE="UTC"

IMG_SIZE="2G"
IMG_FILE="image.img"
QCOW_FILE="image.qcow2"

# This setup makes writing fstab unnecessary because :
#   - root partition is automatically mounted according to its GPT partition type
#   - rootflags including subvol are set with kernel cmdline
# https://uapi-group.org/specifications/specs/discoverable_partitions_specification/

ESP_GPT_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System
ESP_LABEL="ESP"
ESP_SIZE="200M"
ESP_DIR="efi"
ROOT_GPT_TYPE="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" # Linux root (x86-64)
ROOT_LABEL="Debian"
ROOT_SUBVOL="@debian"
ROOT_FLAGS="compress=zstd,noatime,subvol=$ROOT_SUBVOL"

BUILD_DEPENDENCIES+=(
    debootstrap
    debian-archive-keyring
    btrfs-progs
    dosfstools
    qemu-utils
    util-linux
)
PACKAGES+=(
    btrfs-progs
    chrony
    cloud-guest-utils
    cloud-init
    htop
    linux-image-amd64
    man-db
    neovim
    openssh-server
    systemd-boot
    systemd-resolved
    sudo
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
)
UNITS_ENABLE+=(
    cloud-init
    cloud-init-local
    cloud-config
    cloud-final
    ssh
    systemd-boot-update
    systemd-networkd
    systemd-resolved
)

MOUNT="$(mktemp --directory)"
MASK="$(mktemp --directory)"

# Cleanup trap
cleanup() {
    echo "### EXECUTING CLEANUP"
    if findmnt --mountpoint "$MOUNT" >/dev/null; then
        umount --recursive "$MOUNT"
    fi
    if [[ -n $LOOPDEV ]]; then
        losetup --detach "$LOOPDEV"
        LOOPDEV=""
    fi
    rm -rf "$MOUNT"
    rm -rf "$MASK"
}
trap cleanup ERR EXIT

echo "### IMAGE SETUP" >&2
rm -f $IMG_FILE
truncate --size $IMG_SIZE $IMG_FILE

echo "### PARTITIONING" >&2
# Flag 59 marks the partition for automatic growing of the contained file system
# https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
sfdisk --label gpt $IMG_FILE <<EOF
type=$ESP_GPT_TYPE,name="$ESP_LABEL",size=$ESP_SIZE
type=$ROOT_GPT_TYPE,name="$ROOT_LABEL",attrs=59
EOF

echo "### LOOP DEVICE SETUP" >&2
LOOPDEV=$(losetup --find --partscan --show $IMG_FILE)
echo LOOPDEV="$LOOPDEV"
PART1="$LOOPDEV"p1
PART2="$LOOPDEV"p2
sleep 1

echo "### FORMATTING" >&2
mkfs.vfat -F 32 -n "$ESP_LABEL" "$PART1"
mkfs.btrfs --label "$ROOT_LABEL" "$PART2"

echo "### MOUNTING" >&2
mount "$PART2" "$MOUNT"
btrfs subvolume create "$MOUNT/$ROOT_SUBVOL"
btrfs subvolume set-default "$MOUNT/$ROOT_SUBVOL"
umount "$MOUNT"
mount --options "$ROOT_FLAGS" "$PART2" "$MOUNT"

echo "### DEBOOTSTRAP" >&2
debootstrap --arch=amd64 "$RELEASE" "$MOUNT" "$MIRROR"

echo "### CHROOT" >&2
# have to type all this crap because debian doesn't provide arch-chroot equivalent
mount --mkdir=700 "$PART1" "$MOUNT/$ESP_DIR"
mount proc "$MOUNT/proc" -t proc -o nosuid,noexec,nodev
mount sys "$MOUNT/sys" -t sysfs -o nosuid,noexec,nodev,ro
# mask efivars because debian hooks assume we want to install the current machine
mount --bind "$MASK" "$MOUNT/sys/firmware"
mount udev "$MOUNT/dev" -t devtmpfs -o mode=0755,nosuid
mount devpts "$MOUNT/dev/pts" -t devpts -o mode=0620,gid=5,nosuid,noexec
mount shm "$MOUNT/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev
mount run "$MOUNT/run" -t tmpfs -o nosuid,nodev,mode=0755
mount tmp "$MOUNT/tmp" -t tmpfs -o mode=1777,strictatime,nodev,nosuid

rm -f "$MOUNT/etc/machine-id"
cat <<EOF >"$MOUNT/etc/kernel/cmdline"
root=PARTLABEL=$ROOT_LABEL rootflags=$ROOT_FLAGS rw console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0
EOF

chroot "$MOUNT" apt install -y "${PACKAGES[@]}"

echo "### CLOUD IMAGE SETTINGS" >&2
# https://systemd.io/BUILDING_IMAGES/
rm -f "$MOUNT/etc/machine-id"
rm -f "$MOUNT/var/lib/systemd/random-seed"
rm -f "$MOUNT/$ESP_DIR/loader/random-seed"
# Use systemd-repart to grow the root partition
mkdir --parents "$MOUNT/etc/repart.d"
cat <<EOF >"$MOUNT/etc/repart.d/root.conf"
[Partition]
Type=root
EOF
# Cloud Init Settings
cat <<EOF >"$MOUNT/etc/cloud/cloud.cfg.d/custom.cfg"
system_info:
  default_user:
    shell: /usr/bin/zsh
    gecos:
growpart:
  mode: off
resize_rootfs: false
ssh_deletekeys: false
ssh_genkeytypes: []
disable_root: true
disable_root_opts: "#"
EOF

echo "### FIRSTBOOT SETTINGS" >&2
systemd-firstboot \
    --root="$MOUNT" \
    --force \
    --keymap="$KEYMAP" \
    --locale="$LOCALE" \
    --hostname="$HOSTNAME" \
    --timezone="$TIMEZONE" \
    --root-shell=/usr/bin/zsh \
    ;

echo "### NETWORK SETTINGS" >&2
ln -sf /run/systemd/resolve/stub-resolv.conf "$MOUNT/etc/resolv.conf"
cat <<EOF >"$MOUNT/etc/systemd/network/99-ethernet.network"
[Match]
Name=en*
Type=ether

[Network]
DHCP=yes
EOF

echo "### MISC SETTINGS" >&2
# Disable SSH password and root login
cat <<EOF >"$MOUNT/etc/ssh/sshd_config.d/custom.conf"
PermitRootLogin no
PasswordAuthentication no
EOF
# ZSH plugins
cat <<EOF >>"$MOUNT/etc/zsh/zshrc"
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
# Neovim Symlinks
ln -s /usr/bin/nvim "$MOUNT/usr/local/bin/vim"
ln -s /usr/bin/nvim "$MOUNT/usr/local/bin/vi"

echo "### ENABLE UNITS" >&2
systemctl --root="$MOUNT" enable "${UNITS_ENABLE[@]}"

echo "### CLEANUP" >&2
sync -f "$MOUNT/etc/os-release"
fstrim --verbose "$MOUNT/$ESP_DIR"
fstrim --verbose "$MOUNT"
cleanup

echo "### CREATE QCOW2" >&2
qemu-img convert -f raw -O qcow2 "$IMG_FILE" "$QCOW_FILE"

echo "### FINISHED WITHOUT ERRORS" >&2
