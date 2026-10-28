#!/bin/bash
# Boots a GSI image once through Dynamic System Updates (DSU) on the Teclast P80: the image and a
# fresh userdata live in /data/gsi/dsu, the installed system and its data stay untouched, and the
# next reboot returns to the installed system.
# Usage: tools/p80-dsu.sh <raw system.img>   install the image and reboot into it once
#        tools/p80-dsu.sh --wipe             remove the DSU image (~7 GB in /data)
# Needs adb root on the installed system. Two workarounds for this tablet:
# - gsid may not read files in /data/local/tmp (SELinux), so the image goes through a pipe;
# - the boot image's first-stage init is Android 10's: it reads the DSU partition table from
#   /metadata/gsi/dsu/lp_metadata (newer gsid writes it per slot) and finds the backing partition
#   only by its GPT name, while gsid records the kernel name (mmcblk0p17 instead of UDISK); and
#   it does not write /metadata/gsi/dsu/lp_names, which the image's fs_mgr needs.
set -euo pipefail

ADB="${ADB:-adb}"
USERDATA_SIZE=$((4 * 1024 * 1024 * 1024))
D=/metadata/gsi/dsu
sh() { $ADB shell "$@" | tr -d '\r'; }

$ADB root >/dev/null; sleep 2; $ADB wait-for-device
if [ "${1:-}" = "--wipe" ]; then
    sh "gsi_tool wipe; rm -f $D/lp_metadata $D/lp_names; gsi_tool status"
    exit
fi
img="${1:?usage: $0 <system.img> | --wipe}"
[ "$(head -c 4 "$img" | od -An -tx4 | tr -d ' ')" != "ed26ff3a" ] || { echo "$img is sparse; convert it with simg2img" >&2; exit 1; }

$ADB push "$img" /data/local/tmp/dsu.img
sh "cat /data/local/tmp/dsu.img | gsi_tool install --gsi-size $(stat -c %s "$img") \
    --userdata-size $USERDATA_SIZE --no-reboot | tr '\r' '\n' | grep -v '%'; rm /data/local/tmp/dsu.img"

# The Android 10 copy of the partition table, with the backing device under its GPT name
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
slot=$(sh "cat $D/active")
kname=$(sh "readlink -f /dev/block/by-name/UDISK" | sed 's|.*/||')
$ADB exec-out "cat $D/$slot/lp_metadata" > "$tmp/lp_metadata"  # binary: not through sh()
python3 -I "$(dirname "$0")/lp_metadata_rename.py" "$tmp/lp_metadata" "$kname" UDISK "$tmp/lp_metadata.a10"
$ADB push "$tmp/lp_metadata.a10" /data/local/tmp/lp_metadata.a10 >/dev/null
sh "cp /data/local/tmp/lp_metadata.a10 $D/lp_metadata && rm /data/local/tmp/lp_metadata.a10 &&
    chmod 0644 $D/lp_metadata && chcon u:object_r:gsi_metadata_file:s0 $D/lp_metadata"
# Android 11+ first-stage init publishes the DSU partition names for fs_mgr; without them the
# image's fs_mgr fails to read the whole fstab, mounts nothing (no /data, no APEXes but the
# bootstrap ones) and the boot stalls with a black screen.
sh "printf userdata_gsi,system_gsi > $D/lp_names && chmod 0644 $D/lp_names &&
    chcon u:object_r:gsi_metadata_file:s0 $D/lp_names"

# gsi_tool install enables the image for one boot; the Android 10 init marks it disabled before
# booting it, so a failed or finished DSU boot falls back to the installed system.
status=$(sh "cat $D/install_status"); one_shot=$(sh "ls $D/one_shot_boot 2>/dev/null")
[ "$status" = "0" ] && [ -n "$one_shot" ] || { echo "DSU not enabled for one boot ($status)" >&2; exit 1; }
echo "Rebooting into the DSU image once; the boot reason of a failed attempt shows up as"
echo "sys.boot.reason on the installed system afterwards. Remove it with: $0 --wipe"
$ADB reboot
