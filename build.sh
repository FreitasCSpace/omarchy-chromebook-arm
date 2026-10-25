#!/bin/bash

# Builds a bootable Omarchy image for Qualcomm Chromebooks (Snapdragon 7c
# "trogdor", 7c+ Gen 3 "herobrine") that depthcharge boots from a USB stick or
# SD card in developer mode.
#
# It follows the Omarchy ISO's install sequence (omarchy-iso, phases_impl.py)
# inside an Arch Linux ARM root, with first-boot (deferred) provisioning: the
# image carries no user, and the machine's first boot asks for one. Hardware
# setup is deferred to that boot too, through Omarchy's image manifest, so it
# runs against the Chromebook rather than the machine that built the image.
#
# Usage: sudo ./build.sh [--resume] [IMAGE]   (default out/omarchy-chromebook.img)
# Must run on aarch64 (the build chroots into the target root natively).
#
# --resume reuses an image whose package install already finished and reruns
# only the setup after it, for iterating on a failed setup step; a release
# image is always built without it.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
resume=0
if [[ ${1:-} == "--resume" ]]; then
  resume=1
  shift
fi
image=${1:-$here/out/omarchy-chromebook.img}
image_size=${OMARCHY_IMAGE_SIZE:-14G}
# The rc channel, because stable's aarch64 omarchy (4.0.6) predates the
# platform detector, omarchy-pkg-defaults and deferred image hardware setup
# this build relies on; 4.5.0rc1 and later carry them.
channel=${OMARCHY_CHANNEL:-rc}
# Packages are cached on the build host, so a rerun downloads nothing twice.
pkg_cache=$here/dl/pkg
rootfs_tarball=$here/dl/ArchLinuxARM-aarch64-latest.tar.gz
rootfs_url=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
omarchy_ref=$here/upstream
omarchy_key=$here/iso/builder/omarchy.gpg
mnt=$here/out/mnt
log=$here/out/build.log

export PATH=$PATH:/usr/sbin:/sbin

if ((EUID != 0)); then
  echo "Run as root: sudo $0" >&2
  exit 1
fi
if [[ $(uname -m) != "aarch64" ]]; then
  echo "This build chroots into an aarch64 root and must run on aarch64" >&2
  exit 1
fi
for tool in sgdisk losetup mkfs.btrfs bsdtar arch-chroot cgpt; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done

step() { printf '\n==> %s\n' "$*"; }

loop=""
cleanup() {
  if mountpoint -q "$mnt"; then
    umount -R "$mnt" || umount -Rl "$mnt"
  fi
  if [[ -n $loop ]]; then
    losetup -d "$loop" || true
  fi
}
trap cleanup EXIT

# Runs in the target the way the ISO's _run_target_setup_command does.
target() {
  arch-chroot "$mnt" env --unset=XDG_RUNTIME_DIR \
    OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL=/usr/share/omarchy/install \
    OMARCHY_MIRROR="$channel" \
    OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log \
    OMARCHY_LOG_TO_STDOUT=1 \
    MISE_OFFLINE=1 \
    "$@"
}

pacman_install() {
  target pacman -S --noconfirm --needed "$@"
}

mkdir -p "$here/out" "$here/dl"
exec > >(tee "$log") 2>&1

if [[ ! -f $rootfs_tarball ]]; then
  step "Downloading Arch Linux ARM"
  curl -fL -o "$rootfs_tarball.part" "$rootfs_url"
  mv "$rootfs_tarball.part" "$rootfs_tarball"
fi

opts=noatime,compress=zstd
mount_root() {
  mkdir -p "$mnt"
  mount -o "$opts,subvol=@" "${loop}p2" "$mnt"
  mkdir -p "$mnt/home" "$mnt/var/log" "$mnt/var/cache/pacman/pkg"
  mount -o "$opts,subvol=@home" "${loop}p2" "$mnt/home"
  mount -o "$opts,subvol=@log" "${loop}p2" "$mnt/var/log"
  mount -o "$opts,subvol=@pkg" "${loop}p2" "$mnt/var/cache/pacman/pkg"
  mkdir -p "$pkg_cache"
  mount --bind "$pkg_cache" "$mnt/var/cache/pacman/pkg"
}

if ((resume)); then
step "Resuming $image after its package install"
loop=$(losetup -fP --show "$image")
udevadm settle 2>/dev/null || sleep 2
mount_root
else
step "Partitioning $image ($image_size)"
rm -f "$image"
truncate -s "$image_size" "$image"
# KERN-A holds the signed kernel depthcharge boots; root follows it, which is
# what the command line's PARTNROFF=1 points at.
sgdisk -o \
  -n 1:0:+256M -t 1:7f00 -c 1:KERN-A \
  -n 2:0:0 -t 2:8300 -c 2:root \
  "$image" >/dev/null
loop=$(losetup -fP --show "$image")
udevadm settle 2>/dev/null || sleep 2

step "Creating btrfs subvolumes"
mkfs.btrfs -q -f -L omarchy "${loop}p2"
mkdir -p "$mnt"
mount "${loop}p2" "$mnt"
for subvol in @ @home @log @pkg; do
  btrfs subvolume create "$mnt/$subvol" >/dev/null
done
umount "$mnt"
mount_root

step "Unpacking Arch Linux ARM"
bsdtar -xpf "$rootfs_tarball" -C "$mnt"

step "Configuring pacman for Omarchy ($channel)"
install -m 0644 "$omarchy_ref/default/pacman/aarch64/pacman-$channel.conf" "$mnt/etc/pacman.conf"
install -m 0644 "$omarchy_ref/default/pacman/aarch64/mirrorlist-$channel" "$mnt/etc/pacman.d/mirrorlist"
install -m 0644 "$omarchy_key" "$mnt/root/omarchy.gpg"
target pacman-key --init
target pacman-key --populate archlinuxarm
target pacman-key --add /root/omarchy.gpg
omarchy_fpr=$(gpg --with-colons --show-keys "$omarchy_key" | awk -F: '/^fpr/ { print $10; exit }')
target pacman-key --lsign-key "$omarchy_fpr"
rm -f "$mnt/root/omarchy.gpg"
# pacman-key leaves gpg-agent running in the target, which keeps it from unmounting.
target gpgconf --homedir /etc/pacman.d/gnupg --kill all

# Hold every initramfs build until the end, as the ISO does: package installs
# would otherwise rebuild it dozens of times.
mkdir -p "$mnt/etc/pacman.d/hooks"
for hook in 60-mkinitcpio-remove.hook 90-mkinitcpio-install.hook; do
  ln -sf /dev/null "$mnt/etc/pacman.d/hooks/$hook"
done

step "Updating the base system"
target pacman -Syu --noconfirm

# The tarball ships an alarm user (uid 1000) and root:root; the owner created
# on first boot takes uid 1000, and root stays locked.
target userdel -r alarm 2>/dev/null || true
target passwd -l root

step "Installing Omarchy's early packages"
pacman_install base-devel git omarchy-keyring archlinuxarm-keyring omarchy-settings
pacman_install lua51 luarocks
pacman_install omarchy-nvim

step "Installing the Chromebook boot chain"
pacman_install vboot-utils uboot-tools dtc lz4 gptfdisk cloud-guest-utils btrfs-progs linux-firmware-qcom
install -m 0755 "$here/chromebook/omarchy-chromebook-kernel" "$mnt/usr/bin/omarchy-chromebook-kernel"
install -m 0755 "$here/chromebook/omarchy-chromebook-growroot" "$mnt/usr/bin/omarchy-chromebook-growroot"
install -m 0644 "$here/chromebook/omarchy-chromebook-growroot.service" "$mnt/etc/systemd/system/omarchy-chromebook-growroot.service"
install -Dm 0644 "$here/chromebook/chromebook-cmdline" "$mnt/etc/kernel/chromebook-cmdline"
target systemctl enable omarchy-chromebook-growroot.service
fi

install -Dm 0644 "$here/chromebook/zz-omarchy-chromebook.conf" "$mnt/etc/mkinitcpio.conf.d/zz-omarchy-chromebook.conf"
# Arch Linux ARM's vboot-utils ships no developer keys. These are vboot_reference's
# public test keys, which every Chromebook in developer mode accepts.
install -Dm 0644 -t "$mnt/usr/share/vboot/devkeys" "$here/chromebook/devkeys/kernel.keyblock" "$here/chromebook/devkeys/kernel_data_key.vbprivk"
# The Chromebook-only firmware linux-firmware can't ship (the modem image
# trogdor's Wi-Fi runs on), taken from Google's recovery image by
# fetch-chromeos-firmware.sh. Without it the image boots with no Wi-Fi.
if [[ -d $here/dl/firmware ]]; then
  cp -a "$here/dl/firmware/." "$mnt/usr/lib/firmware/"
else
  echo "WARNING: no dl/firmware; run ./fetch-chromeos-firmware.sh first or the Chromebook has no Wi-Fi" >&2
fi

if ((! resume)); then

step "Installing Omarchy and the aarch64-qualcomm package set"
pacman_install omarchy
mapfile -t packages < <(target omarchy-pkg-defaults aarch64-qualcomm | grep -v '^#' | grep -v '^$')
pacman_install "${packages[@]}"
fi

# The ISO installs these from omarchy-other.packages, its hardware bundle,
# rather than the base list: snapper for snapper.sh, and the generic audio and
# Wayland pieces. The x86-only drivers and the Limine boot chain stay out, and
# so does pipewire-jack, which conflicts with the jack2 the desktop pulls in.
pacman_install snapper pipewire pipewire-alsa pipewire-pulse gst-plugin-pipewire libpulse \
  qt6-wayland gtk4-layer-shell webp-pixbuf-loader linux-firmware

step "Writing fstab, locale and hostname"
root_uuid=$(blkid -s UUID -o value "${loop}p2")
cat >"$mnt/etc/fstab" <<FSTAB
# Omarchy on a Chromebook drive (btrfs subvolumes, as the Omarchy ISO lays them out).
UUID=$root_uuid  /                     btrfs  $opts,subvol=@     0 0
UUID=$root_uuid  /home                 btrfs  $opts,subvol=@home 0 0
UUID=$root_uuid  /var/log              btrfs  $opts,subvol=@log  0 0
UUID=$root_uuid  /var/cache/pacman/pkg btrfs  $opts,subvol=@pkg  0 0
FSTAB
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/; s/^#\(pt_PT.UTF-8 UTF-8\)/\1/' "$mnt/etc/locale.gen"
target locale-gen
echo "LANG=en_US.UTF-8" >"$mnt/etc/locale.conf"
echo "omarchy" >"$mnt/etc/hostname"

step "Declaring the image target (hardware setup waits for the Chromebook)"
install -d -m 0755 "$mnt/var/lib/omarchy/image"
printf 'format=1\nplatform=aarch64-qualcomm\n' >"$mnt/var/lib/omarchy/image/target"
chmod 0644 "$mnt/var/lib/omarchy/image/target"

step "Running omarchy-apply-system"
target /usr/bin/omarchy-apply-system --defer-provisioning --first-install

step "Arming first-boot owner setup"
provisioning=$mnt/var/lib/omarchy/provisioning
install -d -m 0755 "$provisioning"
touch "$provisioning/pending"
install -m 0644 "$mnt/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service" \
  "$mnt/etc/systemd/system/omarchy-provision-owner.service"
target systemctl enable omarchy-provision-owner.service

mkdir -p "$mnt/etc/sddm.conf.d"
printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' \
  >"$mnt/etc/sddm.conf.d/99-omarchy-login.conf"
rm -f "$mnt/etc/sddm.conf.d/autologin.conf" "$mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf"
target systemctl enable sddm.service

step "Building the initramfs and the signed kernel partition"
for hook in 60-mkinitcpio-remove.hook 90-mkinitcpio-install.hook; do
  rm -f "$mnt/etc/pacman.d/hooks/$hook"
done
kver=$(basename "$(ls -d "$mnt"/usr/lib/modules/*-ARCH | head -1)")
# autodetect would read this build machine; the first boot rebuilds with it on
# the Chromebook itself (boot-rebuild below), which also brings back the splash.
target mkinitcpio -k "$kver" -g /boot/initramfs-linux.img -S autodetect,kms,plymouth
target omarchy-chromebook-kernel --partition "${loop}p1"
: >"$mnt/var/lib/omarchy/image/boot-rebuild"
# From here on every initramfs build, on the Chromebook, rewrites KERN-A.
install -Dm 0755 "$here/chromebook/90-omarchy-chromebook" "$mnt/etc/initcpio/post/90-omarchy-chromebook"

step "Cleaning up"
target gpgconf --homedir /etc/pacman.d/gnupg --kill all
umount "$mnt/var/cache/pacman/pkg"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$mnt/etc/resolv.conf"

step "Done: $image"
cgpt show "$loop" || true
