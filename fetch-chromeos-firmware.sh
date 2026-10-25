#!/bin/bash

# Copies the Chromebook-only firmware out of Google's ChromeOS recovery image
# into dl/firmware, where build.sh puts it in the Omarchy image.
#
# Trogdor's Wi-Fi (WCN3990) runs on the modem subsystem, which boots signed
# images (qcom/sc7180-trogdor/modem*/mba.mbn, qdsp6sw.mbn) that linux-firmware
# does not ship. They are not redistributable, so the repository carries this
# script instead of the files: every build takes them from Google's own
# published recovery image for the board.
#
# Usage: sudo ./fetch-chromeos-firmware.sh [RECOVERY_ZIP_URL]
# The default is the Duet 5's recovery image (strongbad, which ChromeOS also
# serves to coachz, wormdingler and quackingstick). Newer releases are listed
# under the HOMESTAR hwidmatch in
# https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
url=${1:-https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_16805.36.0_strongbad_recovery_stable-channel_StrongbadMPKeys-v13.bin.zip}
work=$here/dl/recovery
firmware=$here/dl/firmware
zip=$work/${url##*/}
root=$work/root

export PATH=$PATH:/usr/sbin:/sbin

if ((EUID != 0)); then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

loop=""
cleanup() {
  if mountpoint -q "$root"; then
    umount "$root"
  fi
  if [[ -n $loop ]]; then
    losetup -d "$loop" || true
  fi
  rm -f "$work"/chromeos_*.bin
}
trap cleanup EXIT

mkdir -p "$work" "$root"
if [[ ! -f $zip ]]; then
  echo "Downloading ${url##*/}"
  curl -fsSL -C - -o "$zip.part" "$url"
  mv "$zip.part" "$zip"
fi

echo "Unpacking the recovery image"
bsdtar -xf "$zip" -C "$work"
bin=$(ls "$work"/chromeos_*.bin | head -1)

# ROOT-A, partition 3, is the read-only ChromeOS root.
loop=$(losetup -fP --show -r "$bin")
udevadm settle 2>/dev/null || sleep 2
mount -o ro "${loop}p3" "$root"

rm -rf "$firmware"
mkdir -p "$firmware/qcom"
found=0
for dir in "$root"/lib/firmware/qcom/sc7180-trogdor "$root"/lib/firmware/qcom/sc7280-herobrine; do
  if [[ -d $dir ]]; then
    cp -a "$dir" "$firmware/qcom/"
    found=1
  fi
done
if ((!found)); then
  echo "No Chromebook firmware under /lib/firmware/qcom in this recovery image" >&2
  exit 1
fi

find "$firmware" -type f -printf '%P\n' | sort
echo "Firmware ready in $firmware; rerun build.sh to include it"
