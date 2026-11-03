#!/bin/bash

# Makes a ChromeOS recovery USB stick for the Lenovo Duet 5 (homestar) from
# Google's own published recovery image, so ChromeOS can always be put back on
# the internal eMMC (for instance after omarchy-chromebook-install-emmc).
#
# Usage:
#   ./make-chromeos-recovery-usb.sh --download      fetch and verify the image (no root needed)
#   sudo ./make-chromeos-recovery-usb.sh /dev/sdX   write it to a USB stick (>= 8 GB, erased)
#   ./make-chromeos-recovery-usb.sh --list          show the Duet 5 images Google publishes
#
# CHANNEL=beta|ltc|ltr picks another channel than stable.
#
# To recover: power off, hold Esc + Refresh and press Power, insert the stick.
# Recovery also leaves developer mode, so the Chromebook comes back stock.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self=$here/$(basename "${BASH_SOURCE[0]}")
work=$here/dl/recovery-usb
catalog_url=https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json
hwid='HOMESTAR'
channel=${CHANNEL:-stable}

die() {
  echo "make-chromeos-recovery-usb: $*" >&2
  exit 1
}

# Prints "url sha1 filesize file version" for the Duet 5's image on $channel,
# or with channel=list every Duet 5 image in the catalog.
image_entry() {
  mkdir -p "$work"
  curl -fsSL -o "$work/recovery2.json" "$catalog_url"
  python3 - "$work/recovery2.json" "$hwid" "$channel" <<'PY'
import json, sys
catalog, hwid, channel = sys.argv[1], sys.argv[2], sys.argv[3].upper()
entries = [e for e in json.load(open(catalog)) if hwid in e.get("hwidmatch", "")]
if channel == "LIST":
    for e in entries:
        print(f'{e["channel"]:<7} {e["version"]:<12} {e["file"]}')
    sys.exit(0)
match = [e for e in entries if e.get("channel", "").upper() == channel]
if not match:
    sys.exit(f"no {channel} recovery image for {hwid} in the catalog")
e = match[0]
# The catalog's sha1 is the zip's; filesize is the unpacked image's.
print(e["url"], e["sha1"], e["zipfilesize"], e["filesize"], e["file"], e["version"])
PY
}

download() {
  local url zip_sha1 zipsize filesize file version
  read -r url zip_sha1 zipsize filesize file version < <(image_entry)
  [[ -n ${url:-} ]] || die "could not read the recovery catalog"
  local zip=$work/${url##*/} bin=$work/$file
  # .verified holds the zip's SHA-1 it was checked against, then the image's own.
  if [[ -f $bin && -f $bin.verified && $(head -1 "$bin.verified") == "$zip_sha1" ]]; then
    echo "$bin"
    return 0
  fi
  echo "ChromeOS $version ($channel) for the Duet 5" >&2
  # Google's CDN stalls mid-transfer now and then; resume instead of restarting.
  local tries=0
  [[ -f $zip ]] && mv "$zip" "$zip.part"
  until curl -fL --progress-bar --speed-limit 1024 --speed-time 60 -C - -o "$zip.part" "$url" >&2; do
    ((++tries < 30)) || die "download kept failing"
    echo "Download interrupted, resuming ($tries)" >&2
    sleep 5
  done
  mv "$zip.part" "$zip"
  [[ $(stat -c %s "$zip") == "$zipsize" ]] || die "${zip##*/} has the wrong size"
  echo "Checking the SHA-1 against Google's catalog" >&2
  [[ $(sha1sum "$zip" | cut -d' ' -f1) == "$zip_sha1" ]] || die "${zip##*/} does not match Google's SHA-1"
  echo "Unpacking" >&2
  rm -f "$bin" "$bin.verified"
  bsdtar -xf "$zip" -C "$work" "$file"
  [[ $(stat -c %s "$bin") == "$filesize" ]] || die "$file has the wrong size"
  printf '%s\n%s\n' "$zip_sha1" "$(sha1sum "$bin" | cut -d' ' -f1)" >"$bin.verified"
  rm -f "$zip"
  echo "$bin"
}

write() {
  local dev=$1
  ((EUID == 0)) || die "writing a stick needs root: sudo $0 $dev"
  [[ -b $dev ]] || die "$dev is not a block device"
  [[ $(lsblk -dno TYPE "$dev") == disk ]] || die "$dev is a partition; name the whole stick (/dev/sdX)"
  [[ $(lsblk -dno TRAN "$dev") == usb ]] || die "$dev is not a USB drive"

  local root_disk
  root_disk=/dev/$(lsblk -no PKNAME "$(findmnt -nvo SOURCE /)" | head -1)
  [[ $dev != "$root_disk" ]] || die "$dev holds the running system"

  local bin sha1 size
  bin=$(sudo -u "${SUDO_USER:-root}" "$self" --download | tail -1)
  [[ -f $bin && -f $bin.verified ]] || die "no verified image"
  sha1=$(sed -n 2p "$bin.verified")
  [[ -n $sha1 ]] || die "no SHA-1 recorded for $bin; rerun --download"
  size=$(stat -c %s "$bin")
  (($(blockdev --getsize64 "$dev") >= size)) || die "$dev is smaller than the $((size / 1000000)) MB image"

  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "$dev"
  echo
  echo "Everything on $dev will be erased."
  read -r -p "Type the device name ($dev) to continue: " answer
  [[ $answer == "$dev" ]] || die "cancelled"

  for part in $(lsblk -lnpo PATH "$dev" | tail -n +2); do
    umount "$part" 2>/dev/null || true
  done

  dd if="$bin" of="$dev" bs=4M oflag=direct conv=fsync status=progress
  sync
  echo "Verifying what was written"
  [[ $(head -c "$size" "$dev" | sha1sum | cut -d' ' -f1) == "$sha1" ]] || die "the stick does not read back the same; try another stick"
  echo
  echo "Recovery stick ready on $dev. Label it and keep it."
  echo "To use it: power off, hold Esc + Refresh, press Power, insert the stick."
}

case "${1:-}" in
  --download) download ;;
  --list) channel=list image_entry ;;
  /dev/*) write "$1" ;;
  *)
    sed -n '3,16p' "$self" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
