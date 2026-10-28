# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An unofficial **LineageOS 23.2 (Android 16)** build for the **Teclast P80 G3M2** (Allwinner A133, 4× Cortex-A53, 2 GB RAM, stock Android 10 with kernel 4.9.170), packaged as a Podman build environment. Teclast publishes no kernel source, so there is no device tree: the build is the generic target `lineage_arm64_bvN4` (arm64, vanilla, ext4) running on Teclast's own kernel, boot image and vendor partition. Base: LineageOS `lineage-23.2` plus TrebleDroid after MisterZtr's LineageOS_gsi recipe (branch `lineage-23.2`): its local manifest (`manifests/treble-lineage-23.2.xml`, third-party repositories pinned, without `vendor/gapps`) and the patch sets shipped in its `LineageOS_gsi` project (`patches/trebledroid`, `trebledroid-staging`, `personal`), minus what `patches/lineage-23.2/skip` lists, plus this repository's patches. The synced tree lives in the gitignored `src/`.

The repo is meant to be published on GitHub for other P80 G3M2 owners. Keep everything in English, generic and about this tablet only: no serial numbers, MAC addresses or other personal data, no signing keys, no details or paths of anyone's own machines, no references to other projects.

## Status (2026-10-28) and next steps

1. **Done:** build environment; LineageOS 23.2 installed on a P80 G3M2 (EEA) with Teclast's firmware V1.04: `tools/p80-selftest.sh --reboot` without failures, boot ~76 s, SELinux enforcing, hardware as listed in `README.md`.
2. **Releases:** proof-of-concept builds only (AOSP test keys, LineageOS's secure adb defaults). Images never go into git; the maintainer uploads them, compressed with xz (GitHub's 2 GiB asset limit), with `empty-product.img` and `SHA256SUMS`.
3. **Open:** signing with own keys (not in `build.sh`; `vendor/lineage/config/common.mk` includes `vendor/lineage-priv/keys/keys.mk` for build-time signing, APEX keys need their own handling); entropy at boot (no hardware RNG); untested on 23.2: microSD, the hall sensor (magnetic cover), wired headphones, battery life in daily use; standby drain (see *Testing*); candidates for the next build: deep Doze without a motion sensor (*Testing*), the `traced` crash loop and AVF, the setup wizard's time zone (both in *Other findings*); LineageOS 24.0 (see *Outlook*).

## Commands

Build the container image (only when `Containerfile` changes; `build.sh`, `manifests/` and `patches/` are bind-mounted from the checkout, so `git pull` needs no image rebuild):
```bash
podman build -t lineageos-p80-builder .
```

Prepare the bind-mounted directories once (the container runs as `builder`, uid 1000):
```bash
mkdir -p src ccache
podman unshare chown 1000:1000 src ccache
```

Full build, detached (`-e SKIP_SYNC=true` rebuilds the tree as it is; add `-e KEEP_GOING=true -e WITH_ADB_INSECURE=true -e DEBUG_PATCHES=true` for porting and test builds):
```bash
podman run -d --rm \
    -v "$(pwd)":/home/builder/repo:ro \
    -v "$(pwd)/src":/home/builder/android/lineage \
    -v "$(pwd)/ccache":/home/builder/ccache \
    --name p80-build lineageos-p80-builder
```
Output: `src/out/target/product/generic_arm64/p80/lineage-23.2-<date>-UNOFFICIAL-P80[-adb-insecure][-debug].img` and `SHA256SUMS`. Progress: `podman logs -f p80-build` or `src/logs/build-*.log`.

Environment variables of `build.sh`: `BRANCH` (`lineage-23.2`), `TARGET` (`lineage_arm64_bvN4`), `RELEASE` (`bp4a`), `BUILD_TYPE` (`userdebug`), `SYNC_JOBS` (4), `SYNC_RETRIES` (5), `BUILD_JOBS` (`nproc`), `CCACHE_SIZE` (30G), `MIN_FREE_GB` (15), `SYNC_ONLY`, `SKIP_SYNC`, `DEBUG_PATCHES` (also apply `patches/<BRANCH>-debug/`), `KEEP_GOING` (`m -k`), `SUPER_BUDGET` (2514841600, see *Partitions and the super budget*); anything else (e.g. `WITH_ADB_INSECURE`) reaches the build system through the environment.

## Architecture

- `Containerfile`: Ubuntu 20.04 + the LineageOS build dependencies + OpenJDK 17 + `repo`, user `builder` (uid 1000), ccache at `/home/builder/ccache`, `safe.directory '*'` (the bind-mounted tree belongs to another uid). `ENTRYPOINT` is `/home/builder/repo/build.sh` from the bind-mounted checkout.
- `build.sh` (cwd = `src/`): log to `src/logs/build-<UTC>.log` → free-space watchdog (below `MIN_FREE_GB` it kills the process group) → `repo init` every run (`--depth=1 --git-lfs -g default,-darwin,-mips,-notdefault`) → `manifests/treble-<BRANCH>.xml` as local manifest → `clean_interrupted_sync` + `repo sync` with retries (`GIT_HTTP_LOW_SPEED_LIMIT/TIME` against fetches that stall forever) → patches → `bash -n device/phh/treble/rw-system.sh` (a syntax error makes that boot script die silently halfway) → `SYNC_ONLY` stops here → `lunch lineage_arm64_bvN4-bp4a-userdebug` → `m systemimage simg2img` → the image: raw ext4, AVB footer erased (verification is disabled on the tablet and the hash tree costs ~40 MB of the super budget), named after `ro.lineage.version`, `SHA256SUMS`, a hard failure above `SUPER_BUDGET`. Long commands go through `run` (background + `wait`) because bash as PID 1 runs a signal handler only after the foreground command has ended.
- `clean_interrupted_sync`: an interrupted sync poisons the next one. repo treats a project without a `shallow` file as manually unshallowed and fetches its complete history, and a project whose checkout was killed has HEAD at the right revision, so repo skips it and leaves a half-empty worktree. The function removes such gitdirs and `.git` links, stale locks and temporary packs before every attempt.
- Patches, per project: TrebleDroid's, TrebleDroid's staging set and MisterZtr's own, from the `LineageOS_gsi` project in the tree (directories named like `platform_frameworks_base`, mapped to project paths as in its `apply-patches.sh`), then ours from `patches/<BRANCH>/<project path>/`, then `patches/<BRANCH>-debug/` with `DEBUG_PATCHES=true`. `patches/<BRANCH>/skip` lists upstream patches to leave out (`trebledroid|trebledroid-staging|personal/<directory>/<file>`, reasons as comments). Each patched project is reset to `m/<BRANCH>` and patched with `git am --3way`; a patch LineageOS has meanwhile merged (it reverse-applies) is logged and skipped, any other failure stops the build with the patch name. An `applied-patches` marker in the project's gitdir skips projects already in exactly that state, and files whose content did not change get their old mtime back, so one new patch does not make Soong and Kati re-read every patched `Android.bp`/`*.mk`. A project with no patches left goes back to `m/<BRANCH>`.
- `set -euo pipefail` throughout (`set +u` from `envsetup.sh` on): never end a pipeline inside a command substitution with `head`, the SIGPIPE ends the script silently (it once skipped the super budget check); `sed -n 1p` reads to the end.

### Editing patches

- Our patches are `git format-patch` files (author `P80 builder <builder@localhost>`), one change each, the commit message says why. Create them inside the container, where every project in `src/` is in its patched state after a build: `podman run --rm -it --entrypoint bash -v "$(pwd)/src":/home/builder/android/lineage lineageos-p80-builder`, commit the change on top, `git format-patch -1 --stdout`, then `git reset --hard HEAD~1` (the next build re-applies everything). To change an earlier patch, re-apply the series in a `git worktree` at the commit before it, amend and re-export.
- The tree is a shallow `repo` checkout: `git am --3way` cannot build fake ancestors there ("sha1 information is lacking"), so a patch that only applies with a 3-way merge has to be regenerated, e.g. from a full clone of the upstream project.
- Do not run git on the host inside `src/`: with rootless Podman the files belong to a subordinate uid, git may not see the project's `.git` and falls back to an enclosing repository. Use the container.

## Porting notes

Why each of this repository's patches exists (`patches/lineage-23.2/`).

`device/phh/treble`:
- **0001** `bluetooth.core.le.vendor_capabilities.enabled=false`: the Unisoc UWE5622 controller answers the vendor APCF command (`LE_ADV_FILTER`, 0xfd57, sub-command 0xff) with "Unknown HCI Command" twice, as Command Complete and as Command Status (seen in a btsnoop log: `setprop persist.bluetooth.btsnooplogmode full`), and gd's HciLayer aborts on the second event: Bluetooth crash-looped. Without vendor capabilities the stack never sends APCF.
- **0002** LineageOS's adb defaults instead of TrebleDroid's `ro.adb.secure=0` and `persist.sys.usb.config=adb`.
- **0003** only VNDK 29 (the vendor's); the other VNDK snapshots cost ~380 MB that `super` does not have.
- **0004** The vendor's `android.hardware.configstore@1.1-service` died with SIGSYS right after every start (`libminijail: blocked syscall: gettid`: newer libraries call `gettid()`, its Android 10 seccomp policy does not allow it), SurfaceFlinger waited for `ISurfaceFlingerConfigs` forever and the watchdog killed `system_server` every 67 s. `rw-system.sh` (runs `on post-fs` in the `phhsu_daemon` domain) copies the policy to `/mnt/phh`, appends `gettid: 1`, restores the SELinux context and bind-mounts it over the vendor file, like TrebleDroid's keymaster workaround.
- **0005** TrebleDroid's `rw-system.sh` switched privapp permissions to `log`; the vendor's `enforce` stays.
- **0006** model P80, brand and manufacturer Teclast, `ro.build.characteristics=tablet`.
- **0007** LineageOS's `common_full_tablet_wifionly.mk` instead of the phone configuration: not voice/SMS/data capable, no SIM slots, no "SIM card missing".
- **0008** no telephony, IMS or fingerprint feature files (TrebleDroid declares them for every device), no TrebleApp, and of TrebleDroid's ~450 device overlays only highpriomisc, NightMode and Tethering.
- **0009** the launcher, Settings, setup wizard and browser are compiled with `speed` at build time; they ran interpreted after the first boot.
- **0010** 720p camcorder profile: the vendor's `/vendor/etc/media_profiles_V1_0.xml` stops at 480p, although the rear camera (2 MP) delivers 1600×1200 and 1280×720 at 30 fps. `rw-system.sh` bind-mounts a system copy with 720p for camera 0. It must `chmod 0644` the copy: init's umask 077 left it 0600, `MediaProfiles` aborted in the zygote's preload (`CHECK((fp = fopen(xml, "r")))`) and the tablet boot-looped. It mounts only if copy, chmod and chcon all succeed.
- **0011** no phone apps (Dialer, Messaging, SIM toolkit, IMS entitlement).
- **0012** `persist.sys.sf.color_saturation=1.0`, i.e. the Natural color mode by default. In the Boosted mode ColorDisplayService sets a color matrix the Allwinner composer ("SUNXI HWC") cannot apply, so SurfaceFlinger composed every layer on the GPU (`CLIENT`); with Natural all layers are `DEVICE`. The biggest smoothness fix (`dumpsys SurfaceFlinger` shows the composition type per layer and the `colorTransformMatrix`).
- **0013** no color modes, Night Light or extra dim, which would all need GPU composition. LineageOS's common overlay sets `config_setColorTransformAccelerated=true`, and `config_nightDisplayAvailable` and `config_reduceBrightColorsAvailable` are aliases of it, so the overlay overrides it (`cmd overlay lookup --verbose` names the overlay that provides a value).
- **0014** no wallet tile or power-menu plugin, no hotspot or tethering (`ro.tether.denied`). Android 16's SystemUI takes the default tiles from `quick_settings_tiles_new_default`; the old `quick_settings_tiles_default` is not even in its APK.
- **0015** the vendor HALs' debug logging (`audio_platform` ~11 lines/s while audio plays, `AW_PowerHAL` on every touch) raised to warning through `log.tag.*` properties.
- **0016** `PRODUCT_ENABLE_UFFD_GC := false`. `gsi_release.mk` compiles all ART code for the userfaultfd GC, but kernel 4.9 has no userfaultfd: ART runs the concurrent copying GC and rejects every prebuilt odex (read barrier mismatch). odrefresh then recompiled the boot image and system_server into `/data` on the first boot (90 MB, hashed by odsign at every boot without fs-verity: the zygote started at 150 s instead of 17 s), and the apps ran interpreted until background dexopt.
- **0017** the stock firmware's memory settings: `ro.config.per_app_memcg=false`, `ro.lmk.critical_upgrade=true`, `dalvik.vm.heapgrowthlimit=128m`. With `ro.config.low_ram` and no explicit setting, lmkd puts every app into its own memory cgroup with a soft limit (0 for cached apps, 8 MB for the launcher), and the 4.9 kernel's cgroup v1 soft-limit reclaim swaps exactly those apps out. Measured with `tools/p80-appswitch.sh`: swap out/in ~180/111 MB versus ~5/0 MB, the second round with all apps cached 7.7–9.7 s versus 2.7–2.9 s, launcher ANRs gone.
- **0018** LineageOS's naming for unofficial builds, `23.2-<date>-UNOFFICIAL-P80`, instead of the generic `VANILLA-EXT4-GSI`.

`packages/modules/Bluetooth` **0001**: on every suspend and resume the Unisoc WCN kernel driver sends its own vendor commands to the controller (kernel log: `bt_tx_powerchange`, `marlin_sdio_write +++ op 0xFD09`, at suspend also `0xFD0D`; `woble_data_recv opcode: 0xFD09`), and the controller's responses reach the stack as well. Android 10's stack logged and dropped such events; gd aborts (`hci_layer.cc on_hci_event: Received COMMAND_COMPLETE(0x0e) event with OpCode Unknown OpCode(0xfd09) without a waiting command`), 30 times in three hours of sleep. The patch drops Command Complete/Status events of vendor-specific opcodes (OGF 0x3f) the stack is not waiting for, with a warning. Verified: 39 suspends in 25 minutes, 144 dropped events, no crash.

Upstream patches left out (`skip`): MisterZtr's own additions that LineageOS does not have, among them "securize" (makes the system claim a locked bootloader and green verified boot), privapp `log`, Bluetooth off by default and a hidden OEM-unlocking switch; TrebleDroid staging `platform_device_phh_treble/0002` (no longer applies, it only guards a sysfs write for a Lenovo pen); and staging `platform_frameworks_native/0006`, which forces the composer's power OFF and ON at boot (for MediaTek composers left on by the bootloader). The Allwinner display driver drops a runtime-PM reference on that first OFF but takes none on the following ON, so `/sys/devices/platform/soc/6000000.disp/power/runtime_usage` went to -1 and the display autosuspended 5 s (`autosuspend_delay_ms`) after every screen-on while Android believed it was on.

Other findings, no patch needed:
- eBPF: Android 16's `NetBpfLoad` passes on 4.9 with TrebleDroid's staging relaxations (the kernel-version checks only log `[GSI] Android 25Q4 requires kernel 5.10.`), and `/sys/fs/bpf` gets the netd, tethering and net_shared programs. The platform's `netbpfload.rc` is a stub (`/system/bin/false` with `reboot_on_failure reboot,netbpfload-missing`) that the Tethering APEX's `netbpfload.35rc` overrides: a `reboot,netbpfload-missing` boot reason means that APEX's service was never defined (APEX not active), not necessarily a kernel refusal. The kernel has `CONFIG_BPF_SYSCALL` but no `CONFIG_BPF_JIT`. Never fake the kernel version with `ro.bpf.kver_override`.
- Audio: the vendor's only audio HAL is HIDL `android.hardware.audio@5.0`, whose framework support AOSP removed in Android 15 (commit 559e9765c535); TrebleDroid's `platform_frameworks_av/0025` restores it. Without it `audioserver` crash-loops and `system_server` waits for audio forever.
- `rw-system.sh` exits with status 1 at its last line (the Lenovo pen write) on this tablet: harmless.
- The kernel has no cpusets, schedtune or blkio cgroups: init's task-profile errors (`/dev/cpuset/...`) are harmless and the same on stock.
- Media: Teclast's OMX codecs (`OMX.allwinner.video.*`: decoders for H.264, HEVC, VP9, VP8, MPEG-1/2/4, H.263, VC-1 and more, an H.264 encoder) work with Android 16.
- Wi-Fi: `sprdwl_ng` has no WPA3-SAE (Android hides WPA3-only networks) and the country code stays `null` without a modem (`cmd wifi force-country-code enabled <CC>` for testing).
- Release builds without `WITH_ADB_INSECURE` set `ro.debuggable=0` (LineageOS's `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG`), as official builds do; Developer options → "Rooted debugging" (LineageOS's `adb_root` service) still allows `adb root`.
- With USB debugging off the tablet does not enumerate on USB at all; with a computer connected it never suspends (see *Testing*).
- The display driver logs ~2,150 `disp dma map fail` during boot, none afterwards.
- Time zone: without telephony or a location time zone provider nothing detects it, and the setup wizard's date and time page (`packages/apps/SetupWizard`, `DateTimeActivity`) sets `Pacific/Midway` (UTC−11) unless the user picks a zone. The fresh install's zone (GMT) is not in its offset-sorted list, so it selects nothing; the spinner falls back to the first entry and reports that to its `OnItemSelectedListener`, which applies it with `AlarmManager.setTimeZone()`. A candidate for a setup wizard patch; for now the README tells users to set their zone.
- `traced` (Perfetto) crash-loops after every boot until init stops it (`sys.init.updatable_crashing_process_name=traced`; apexd then logs "Native process 'traced' is crashing. Attempting a revert" and finds nothing to revert). AVF's `packages/modules/Virtualization/build/apex/product_packages.mk` sets `traced.relay_producer_port=vsock://-1:2010`, and kernel 4.9 (no `extended_socket_class`) classes the vsock socket as plain `socket`, which the policy does not allow (`avc: denied { create } … tclass=socket`), so the service fails to start. AVF cannot work here anyway (no `/dev/kvm`) and `com.android.virt` takes 95 MB of the image: candidates are an empty `traced.relay_producer_port` or leaving AVF out. `tools/p80-selftest.sh` misses it because traced ends up `stopped`, not `restarting`.

## Device facts and installation

| Property | Value |
| --- | --- |
| Product | `ro.product.device` `P80_G3M2_EEA`, model `P80_EEA` (EEA variant) |
| Stock build | `V1.04_20210609`, Android 10 (`QP1A.191105.004`), security patch 2020-12-05 |
| Kernel | 4.9.170, built 2021-06-09 with clang 8 from Allwinner's longan SDK for A100/A133 |
| ABI | `arm64-v8a,armeabi-v7a,armeabi`, `zygote64_32`: arm64 images |
| Treble | `ro.treble.enabled=true`, VNDK 29, `plat_sepolicy_vers.txt` 29.0, VINTF target-level 4, HIDL HALs only |
| Partitions | non-A/B, dynamic `super`, separate `recovery`, `vbmeta` + `vbmeta_system` + `vbmeta_vendor`, data partition `UDISK` (f2fs, file-based encryption) |
| Memory | 2 GB, `ro.config.low_ram=true`, zram |
| Hardware | PowerVR GE8300 (GLES 3.2, DDK 1.11@5516664), Unisoc UWE5622 Wi-Fi/Bluetooth (`sprdwl_ng`), Silead touch (`gslX680`), 800×1280 at 213 dpi, AXP803 PMIC, accelerometer (`mir3da`, the only sensor), hall sensor |

Kernel config (`/proc/config.gz`): BPF syscall and cgroup BPF, but no BPF JIT; no binderfs, no userfaultfd, no EROFS (the system image is ext4), no `CONFIG_HW_RANDOM` (the kernel's CRNG initialises late), `CONFIG_PANIC_TIMEOUT=0` (a kernel panic hangs instead of rebooting), `CONFIG_MAGIC_SYSRQ=y`, no pstore backend. The firmware's `vmlinux.fex` holds the complete kernel ELF with DWARF debug info (`CONFIG_MODVERSIONS=y`, no module signing).

Secure boot (`/sys/class/sunxi_info/sys_info`): `sunxi_secure: secure`, `sunxi_rotpk: 0` (the root key hash is not burned, see *Outlook*). The bootloader passes its own device tree to the kernel (the one in the signed boot package plus the unsigned `dtbo` overlays), not the one in `boot.img`.

USB IDs: adb `1f3a:1001`, bootloader fastboot `1f3a:1010`, fastbootd `18d1:4ee0`; Linux needs a udev rule for vendor `1f3a` (README).

### Partitions and the super budget

`sys_partition.fex`: bootloader 32 MiB, env 16, boot 32, **super 2.5 GiB**, misc 16, recovery 32, cache 1.5 GiB (unused), vbmeta/vbmeta_system/vbmeta_vendor 16 each, metadata 16, private 16, frp 0.5 (holds the OEM-unlock byte), dtbo 2, media_data 16, UDISK the rest. `super` (group `sb`, maximum 2,675,965,952 bytes) holds `system` 884,772,864, `vendor` 156,930,048 and `product` 1,134,882,816 bytes on stock. With `product` replaced by a 4 MiB empty ext4, **the system image may be at most 2,514,841,600 bytes** (`SUPER_BUDGET`); the 23.2 image is ~2.35 GB.

### Flashing, in detail

- `fastboot oem unlock` answers `OKAY` in a fraction of a second, without a prompt on the screen, and erases `UDISK`; "Ability is 0" means the OEM-unlocking switch (last byte of `frp`) is off. Afterwards the bootloader refuses most commands, `getvar` included, with `secure mode,fastboot limited used`; `fastboot flashing unlock` is unknown. Everything else happens in fastbootd (`fastboot reboot fastboot`, whose host command may time out while the tablet reboots; `adb reboot fastboot` from Android goes there directly).
- fastbootd: `max-download-size` 512 MiB (fastboot splits raw images itself; "Invalid sparse file format at header magic" is informational), it resizes the logical `system` partition when flashing, it does not know `cache`, and `fastboot -w` targets a `userdata` partition that does not exist: use `fastboot erase UDISK`.
- vbmeta: Teclast's own `vbmeta.img` (`vbmeta.fex` in the firmware) flashed with `--disable-verity --disable-verification`; `vbmeta_system` and `vbmeta_vendor` stay stock. The system image carries no AVB footer.
- First boot after erasing `UDISK`: Android formats the data partition and reboots once (`sys.boot.reason=reboot,factory_reset`); the setup wizard appears after ~4 minutes, later boots take ~75 s.
- Avoid: `fastboot reboot recovery` (on a PF1506 photo frame with the same A133 platform it left the device in a recovery menu without USB: https://github.com/OdyNobody/photo-frame-dashboard/blob/ben-pf1506-review/docs/pf1506-a133-lineageos.md); reading `/sys/power/wakeup_count` over adb (it blocks while wakeup events are active, i.e. always with USB connected); `setenforce 0` or other SELinux changes for tests.
- Never flash Teclast's Android 11 firmware for the G3M3 (`P80_EEA`, kernel 5.4) on a G3M2: another manufacturer's board with other panels, touch configuration, cameras and DRAM tables.
- Stock firmware: Teclast's firmware lookup https://www.teclast.com/en/firmware/fchk.php?c=G3M2 (EEA V1.04: `P80(G3M2)_Android 10.0_EEA_V1.04_SZ.rar`, 961,783,684 bytes, SHA-256 `72919fc0c7598ad93994d19f65849fa7747961f19d8997c377d56fe3bf30bbf3`). The RAR holds `Firmware/Firmware.img`, an unencrypted PhoenixSuit IMAGEWTY v0x300 image (`tools/imagewty_extract.py` lists and extracts its items), plus PhoenixSuit for Windows and Teclast's instructions. `super.fex` is an Android sparse image (`simg2img`, then `lpdump`/`lpunpack`). Back to stock from fastbootd (untested): Teclast's `system`, `product`, `vendor` and the unmodified `vbmeta`, then `fastboot erase UDISK`. Full reflash: PhoenixSuit, or FEL mode (Vol+ while plugging in USB and pressing Power repeatedly, per Teclast's tutorial; untested).

## Testing

- `tools/p80-selftest.sh [--reboot]` (adb): identity, SELinux, privapp, adb authorization, boot health (crash buffer, restarting services, watchdog, seccomp), the patches' effects (configstore policy, 720p profile, no telephony, wallet, tethering or color modes), Settings and quick-settings UI through uiautomator, composition and color matrix, dexopt state, memory settings, Wi-Fi, internet and DNS, Bluetooth off/on, audio, cameras, codecs, accelerometer; with `--reboot` also the boot time. The exit code is the number of failures; root-only checks are skipped without `adb root`.
- `tools/p80-appswitch.sh [rounds]`: launches 8 apps per round with `am start -W` and reports COLD/WARM/HOT and times, kswapd CPU, major faults, swap traffic, memory PSI, lmkd kills and new ANRs. Run it right after a boot or a framework restart.
- Sleep: the tablet never suspends while USB is connected to a computer (kernel wakeup source `usb_connecting` in `/sys/kernel/debug/wakeup_sources`). For suspend or battery tests unplug it and read the results afterwards (`/sys/kernel/debug/suspend_stats`, `dumpsys batterystats`; enlarge the log buffers first with `logcat -G 4M`, the vendor sets main and crash to 4 MB, system to 1 MB). `dream:doze` (ambient display) does not block suspend.
- Standby (2026-10-28, 2 h 49 min unplugged, screen off, Wi-Fi connected at 5 GHz, Bluetooth and location on): 100 → 96 %, 166 mAh, about 1.3 %/h (`dumpsys batterystats` estimates 3 days 5 h from full). The CPU was awake 3.8 % of the time (136 suspends, 31 aborted), and Android caused only 12 of the wakeups (8 light-Doze maintenance windows, 3 Settings battery jobs, 1 JobScheduler); the rest came from the Wi-Fi/Bluetooth chip (`bt_wake_isr` 121 interrupts, `sdiohal_*`) and the AXP803 battery driver (`axp803-battery`, 28 wakeups). About 85 % of the charge goes while the SoC is suspended: healthd's current right after a resume (`c=` in dmesg, mA on this driver) reads 46–59 mA, awake 140–240 mA. Each suspend takes 1.1–1.7 s in Teclast's drivers (`PM: suspend of devices complete after …`): the display driver runs its panel-off sequence (`disp_suspend: backlight disable`) and the touch driver powers the gslX680 down and up on every cycle (its I2C bus, `twi0`, took ~3 million interrupts in the test, ~22,000 per cycle, and none while the tablet is awake with the screen off). Deep Doze never starts: `DeviceIdleController.scheduleAlarmLocked()` schedules nothing while `config_autoPowerModeUseMotionSensor` is true and there is no significant-motion sensor (`mMotionSensor=null`), so only light Doze runs; an overlay setting it to false would allow deep Doze. At every suspend the kernel's firmware cache fails to read `rgx.fw.*` (`same_process_hal_file`, SELinux denial for `kernel`), harmless: the GPU works after resume.
- **DSU** (`tools/p80-dsu.sh <image>`, `--wipe` removes it; needs `adb root` on the installed system) boots another system image once from `/data/gsi/dsu` with a fresh 4 GB userdata; the installed system and its data stay untouched and the next reboot returns to it. Three workarounds for this tablet: gsid may not read `/data/local/tmp` (SELinux), so the image goes through a pipe; the boot image's first-stage init is Android 10's, which reads the DSU partition table from `/metadata/gsi/dsu/lp_metadata` (newer gsid writes it per slot) and finds the backing partition only by its GPT name (`UDISK`, not `mmcblk0p17`; `tools/lp_metadata_rename.py` rewrites it and fixes the checksums); and it does not write `/metadata/gsi/dsu/lp_names`, without which Android 16's `fs_mgr` fails the whole fstab (no `/data`, only the bootstrap APEXes, a black screen). Every new DSU image means a new userdata, so the setup wizard again; the one-shot boot works across Android versions.
- Boot problems before adb: `DEBUG_PATCHES=true` adds a "black box" (a `p80-debug` service from `on init` writes dmesg, logcat, properties and processes to `/metadata/p80-debug/` every 5 s and reboots through sysrq after 10 minutes without `sys.boot_completed`; `kernel.panic=10`) and stops NetBpfLoad's `reboot_on_failure`. Read `/metadata/p80-debug/` from the installed system afterwards and delete it (`/metadata` has 16 MiB). Never publish such images.
- Release check: SELinux enforcing, empty crash buffer (`logcat -b crash -d`), no `restarting` services, suspend on battery.

## Outlook: LineageOS 24.0 and an own kernel

- On the stock 4.9 kernel, LineageOS 23.2 is the end of the line. Android 17's `NetBpfLoad` (lineage-24.0) aborts below kernel 5.10 and without a BPF JIT (https://github.com/LineageOS/android_packages_modules_Connectivity/blob/lineage-24.0/bpf/loader/NetBpfLoad.cpp), so it would only run in a reduced "BPF-less" mode like RestlessOS's (https://github.com/cawilliamson/treble_restlessos), and Android 17 removed the framework side of HIDL `light@2.0`, the tablet's backlight HAL (https://github.com/LineageOS/android_frameworks_base/commit/459627afd234c352d9e9a7f780f07ad1f825b110). TrebleDroid has no Android 17 branch yet.
- An own kernel looks possible. The A133 runs in secure mode, but the root key hash is not burned, and the boot ROM accepts any root key until it is ("until the ROTPK_HASH eFuse is programmed, any 'root key' will be accepted by the BROM", mainline U-Boot `tools/sunxi_toc0.c`): a self-signed TOC0 could start an own bootloader with an own device tree. Untested; a microSD card is the safe first experiment, and FEL stays reachable.
- Kernel base: Allwinner's longan 5.15 (public as https://github.com/chainsx/kernel-sun50iw10, branch `main`) carries the board drivers (display, video engine, cameras, UWE5622, touch, sensors, AXP803). The PowerVR kernel module matching the vendor's user-space DDK 1.11@5516664 is public in the longan 4.9 tree and would need a port to 5.15. Mainline Linux has basic support only (`sun50i-a133-teclast-p80.dts`, no display or GPU). The display panels' init sequences exist only in Teclast's kernel binary (as DWARF-typed tables in `vmlinux`). Teclast does not publish the kernel source and declined a request for it.

## Host notes

- Disk: a synced 23.2 tree plus a full build take ~220 GB; the free-space watchdog stops the build before the disk fills.
- RAM: Soong's analysis of the 23.2 tree needs well over 30 GB at its peak and swaps for a long time with less. Do not run two Android builds on one machine at the same time.
- Never write into `src/` outside `out/` between incremental builds: Soong re-runs every glob whose directory changed, and a changed result starts the full analysis again (`Globs changed, rerunning soong... One culprit glob` in the log names the cause). Run Python tools from the tree with `python3 -B`.
- Rootless Podman: `podman unshare chown 1000:1000 src ccache` gives the container user the folders; files under `src/` then belong to a subordinate uid, so read them normally and delete them with `podman unshare rm -rf src`. If the checkout's group is not mapped in the user namespace (e.g. a setgid group inherited from a parent directory), run `chgrp "$(id -gn)" src ccache && chmod g-s src ccache` first. The checkout must be world-readable (`o+rX`) for the container user.

## Conventions

- English, generic, about the P80 G3M2 only (see *What this repo is*).
- Images never go into git. Never publish images built with `WITH_ADB_INSECURE` or `DEBUG_PATCHES` (their names end in `-adb-insecure` or `-debug`).
- One change per patch, the commit message explains why; record findings and the reason for every patch in this file.
