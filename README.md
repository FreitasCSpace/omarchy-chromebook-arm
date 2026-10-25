# Omarchy for the Lenovo IdeaPad Duet 5 Chromebook

A bootable [Omarchy](https://omarchy.org) 4 (aarch64) image for the **Lenovo IdeaPad Duet 5 Chromebook** (board `homestar`, Snapdragon 7c Gen 2 / SC7180). It runs from a USB stick or SD card through the Chromebook's own bootloader (depthcharge) and leaves ChromeOS on the internal drive untouched: on the developer-mode boot screen, Ctrl+D starts ChromeOS and Ctrl+U starts Omarchy.

**The Duet 5 is the only device this is tested on and the only one it supports.** Other Snapdragon 7c Chromebooks are close relatives; see [Other devices](#other-devices).

## Status

| Hardware | State |
| --- | --- |
| Boot from USB / SD (depthcharge, Ctrl+U) | works |
| OLED display, detachable keyboard, battery | works |
| Wi-Fi | works (needs the ChromeOS modem firmware, see [Build](#build)) |
| Bluetooth | works |
| Speakers | works (four-channel profile fix, see below) |
| Front camera (OV5675) | works, through libcamera's software ISP and PipeWire |
| Rear camera (OV8856) | **not working**: the sensor does not answer on I2C yet |
| Touchscreen, pen, suspend, headphone jack | not verified |
| Install to the internal drive / dual boot | not supported |

## How it works

- **Base:** Arch Linux ARM with its `linux-aarch64` kernel, plus Omarchy's official aarch64 repositories on the **rc** channel (`pkgs.omarchy.org/rc/aarch64`). Stable's aarch64 `omarchy` (4.0.6) predates the platform detector, `omarchy-pkg-defaults` and deferred hardware setup this build relies on; 4.5.0rc1 has them. Set `OMARCHY_CHANNEL=stable` once stable catches up.
- **Install:** `build.sh` follows the Omarchy ISO's install sequence (early packages, `omarchy-pkg-defaults aarch64-qualcomm`, `omarchy-apply-system --defer-provisioning`) inside the image. Hardware setup waits for the first boot on the Chromebook, through Omarchy's image manifest.
- **Boot:** there is no UEFI or Limine. `omarchy-chromebook-kernel` packs the kernel, the initramfs and the homestar device trees into a FIT image, signs it with vboot's developer keys and writes it to the `KERN-A` partition. A mkinitcpio post hook (`/etc/initcpio/post/90-omarchy-chromebook`) does this again after every kernel or initramfs update. `chromebook/devkeys/` carries vboot_reference's public test keys (the ones every Chromebook in developer mode accepts), because Arch Linux ARM's `vboot-utils` ships none.
- **First boot:** the root partition grows to fill the drive, hardware setup runs, the initramfs is rebuilt for the machine, and Omarchy's first-run wizard asks for a user name and password.

Image layout: `p1 KERN-A` (256 MiB, signed kernel) and `p2 root` (btrfs with `@`, `@home`, `@log` and `@pkg`, as the Omarchy ISO lays them out). The image is not encrypted.

### Duet 5 fixes

| Problem | Fix |
| --- | --- |
| The initramfs could not find the root from depthcharge's `root=PARTUUID=%U/PARTNROFF=1` | the command line names the root by its btrfs UUID |
| 30 s after boot the kernel turned off `pp3300_hub`, the internal USB hub's rail, and the boot drive vanished (Arch Linux ARM doesn't build `CONFIG_USB_ONBOARD_DEV`, the driver that claims it) | `regulator_ignore_unused` on the command line |
| No Wi-Fi: the WCN3990 runs on the modem, which needs Google-signed firmware and `rmtfs` to boot it | `fetch-chromeos-firmware.sh` takes the firmware from Google's recovery image; `rmtfs` and `qrtr` are installed, with the modem's EFS files created before `rmtfs` starts |
| Speakers showed up as PipeWire's "Dummy" output: the Duet 5's speaker DAI only opens with four channels, alsa-ucm-conf asks for two | `omarchy-chromebook-ucm` patches the SC7180 profile at boot and after every alsa-ucm-conf update; WirePlumber upmixes stereo to the rear pair |
| `btrfs-overlayfs` (the mkinitcpio hook for booting Limine snapshots) has nothing to boot without Limine | removed by `zz-omarchy-chromebook.conf`; snapper still takes snapshots |

### Cameras

Mainline Linux has no camera support for the SC7180 yet: CAMSS (Qualcomm's camera subsystem driver) doesn't know the chip, `sc7180.dtsi` has no CAMSS or CCI node, and the homestar device tree describes no sensors. The port adds all three:

- `camera/0001-media-qcom-camss-add-sc7180-support.patch` adds SC7180 to Linux 7.3's CAMSS, modelled on its SDM670 support, with the CSIPHY 1.2.2 lane settings from George Chan's [SC7180 CAMSS series (2024)](https://patchwork.kernel.org/project/linux-media/cover/20240624-b4-sc7180-camss-v3-0-89ece6471431@gmail.com/), which was never merged.
- `camera/dkms/` is that patched driver plus the OV5675 sensor driver (which Arch Linux ARM doesn't build) as a DKMS package, so every kernel update rebuilds them.
- `camera/sc7180-trogdor-homestar-camera.dtsi` describes CAMSS, CCI0 and the front OV5675, wired as ChromeOS's own homestar device tree wires them. `camera/build-dtbs.sh` builds the homestar DTBs with it from the kernel's source, and `omarchy-chromebook-kernel` uses them instead of the kernel's.
- libcamera's simple pipeline with its software ISP turns the raw sensor output into video, and `camera/70-dma-heap.rules` lets the logged-in user open the dma-buf heaps it allocates from. Browsers reach the camera through PipeWire.

The rear OV8856 sits on CCI0 master 1 at 0x10 and does not acknowledge on I2C with the power-up ChromeOS's device tree describes, so it is left out of the device tree for now (CAMSS waits for every sensor in its graph before it registers any). Its wiring is documented in the `.dtsi`.

## Build

On an aarch64 Linux machine (the Duet 5's own Linux development environment works):

```bash
sudo apt install vboot-kernel-utils cgpt u-boot-tools arch-install-scripts libarchive-tools \
  btrfs-progs gdisk lz4 device-tree-compiler cpp
git clone https://github.com/FreitasCSpace/omarchy-chromebook-arm.git
cd omarchy-chromebook-arm
git clone --depth 1 https://github.com/basecamp/omarchy.git upstream
git clone --depth 1 https://github.com/omacom/omarchy-iso.git iso
sudo ./fetch-chromeos-firmware.sh   # Wi-Fi modem firmware from Google's recovery image
sudo ./build.sh                      # -> out/omarchy-duet5.img (14 GiB, fits a 16 GB stick)
```

The modem firmware (`qcom/sc7180-trogdor/modem*/{mba,qdsp6sw}.mbn`) is signed by Google, isn't in linux-firmware and can't be redistributed, so the repository carries the script that extracts it rather than the files. Without it the image boots with no Wi-Fi.

Packages are cached in `dl/pkg`, so a second build downloads nothing twice. `sudo ./build.sh --resume` reuses an image whose package install already finished and reruns only the setup after it; it is for iterating on a failed step, and a release image is always built without it.

## Install and boot

> **Warning:** turning on developer mode powerwashes the Chromebook. That erases everything on it, **including the Linux development environment and its files**. Back up first. If developer mode is already on, skip step 2.

1. Write the image to a USB stick or SD card of 16 GB or more: `sudo dd if=out/omarchy-duet5.img of=/dev/sdX bs=4M status=progress conv=fsync`, or use balenaEtcher. From ChromeOS's Linux environment, first connect the stick to Linux (Settings → Developers → Linux development environment → Manage USB devices).
2. Turn on developer mode: power off, hold Esc + Refresh and press Power, then press Ctrl+D and confirm.
3. Allow booting from USB. `sudo` doesn't work in crosh's `shell`, so use the VT-2 console: press Ctrl+Alt+→ (or Ctrl+Alt+F2), log in as `chronos`, and run
   ```bash
   sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0
   ```
   `sudo crossystem dev_boot_usb` prints `1` when it took (without a trailing newline, so it lands right before the next prompt). Ctrl+Alt+← goes back to ChromeOS.
4. Plug in the stick, reboot, and press **Ctrl+U** on the "OS verification is OFF" screen (newer firmware: choose "Boot from external disk").
5. The first boot takes a few minutes. Omarchy's wizard then asks for your user.

To get back to ChromeOS, reboot without the stick or press Ctrl+D.

## Other devices

These Chromebooks use the same Snapdragon 7c (SC7180, "trogdor") platform and have device trees in mainline Linux, so they are the most likely candidates for a port. **None of them is tested or supported.** Each needs at least its own device tree in `omarchy-chromebook-kernel`, its ChromeOS recovery image in `fetch-chromeos-firmware.sh`, and a check of its audio profile; the camera wiring and sensors differ per board.

| Board | Device |
| --- | --- |
| `wormdingler` | Lenovo IdeaPad Duet 3 Chromebook (Lenovo Chromebook Duet 3) |
| `coachz` | HP Chromebook x2 11 |
| `quackingstick` | Acer Chromebook Tab 510 |
| `lazor` | Acer Chromebook Spin 513 (CP513-1H / 1HL) |
| `limozeen` | Acer Chromebook 511 (C741L / C741LT) |
| `pompom` | Dynabook Chromebook C1 |
| `kingoftown` | HP Fortis 11 G9 Q Chromebook |
| `pazquel` | Libera-Merdeka Chromebook C100/C110/C120/C150, Orbic Chromebook, Prowise Chromebook 360 G1 |

`wormdingler`, `coachz` and `quackingstick` share the Duet 5's recovery image (strongbad), so their Wi-Fi firmware comes from the same download. The Snapdragon 7c+ Gen 3 (SC7280, "herobrine") boards in mainline are reference designs that never shipped.

## Credits

[Omarchy](https://github.com/basecamp/omarchy) and its ISO's install sequence, [Arch Linux ARM](https://archlinuxarm.org), the mainline SC7180 and trogdor work in Linux, and George Chan's SC7180 CAMSS series. `camera/dkms/` contains Linux kernel source, under the GPL-2.0 its files name.
