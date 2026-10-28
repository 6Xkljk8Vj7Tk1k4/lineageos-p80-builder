#!/bin/bash
# LineageOS 23.2 (Android 16) GSI for the Teclast P80 (G3M2: Allwinner A133, kernel 4.9).
# Container entrypoint: syncs LineageOS plus the TrebleDroid parts (manifests/treble-<BRANCH>.xml)
# into the bind-mounted /home/builder/android/lineage, applies the TrebleDroid and MisterZtr
# patches shipped in the LineageOS_gsi project and ours (patches/<BRANCH>/), builds the system
# image and checks that it fits the tablet's super partition.
# All knobs are environment variables (`podman run -e NAME=value`), see CLAUDE.md.
set -euo pipefail

BRANCH="${BRANCH:-lineage-23.2}"
TARGET="${TARGET:-lineage_arm64_bvN4}"   # vanilla (no GApps), ext4: kernel 4.9 has no EROFS
RELEASE="${RELEASE:-bp4a}"
BUILD_TYPE="${BUILD_TYPE:-userdebug}"
SYNC_JOBS="${SYNC_JOBS:-4}"
SYNC_RETRIES="${SYNC_RETRIES:-5}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
CCACHE_SIZE="${CCACHE_SIZE:-30G}"
# Stop syncing/building when the source volume has less free space than this.
MIN_FREE_GB="${MIN_FREE_GB:-15}"
# "true" = only sync and patch, do not build.
SYNC_ONLY="${SYNC_ONLY:-false}"
# "true" = do not repo init/sync, only (re)apply the patches and build.
SKIP_SYNC="${SKIP_SYNC:-false}"
# "true" = also apply patches/<BRANCH>-debug/ (diagnostics only, never publish the image).
DEBUG_PATCHES="${DEBUG_PATCHES:-false}"
# "true" = `m -k`: keep building after errors to collect all of them in one run.
KEEP_GOING="${KEEP_GOING:-false}"
# Largest system image the tablet takes: maximum of super's group "sb" minus the stock
# vendor minus a 4 MiB empty product (see CLAUDE.md, "Partitions and the super budget").
SUPER_BUDGET="${SUPER_BUDGET:-2514841600}"

TOP=/home/builder/android/lineage
REPO=/home/builder/repo
cd "$TOP"

LOG_DIR="$TOP/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ">>> Log: $LOG_FILE"
echo ">>> ${BRANCH} ${TARGET}-${RELEASE}-${BUILD_TYPE} | jobs=${BUILD_JOBS} | ccache=${CCACHE_SIZE}"

free_gb() { df -Pk "$TOP" | awk 'NR==2 {print int($4 / 1048576)}'; }
check_space() {
    local f; f=$(free_gb)
    if [ "$f" -lt "$MIN_FREE_GB" ]; then
        echo "!!! Only ${f} GB free on the source volume (minimum ${MIN_FREE_GB} GB) - stopping."
        return 1
    fi
}
# bash as PID 1 ignores signals without a handler, and runs a handler only after the
# foreground command has finished. Long commands therefore go through `run` (`wait`
# returns as soon as a signal arrives) and the handler stops the whole process group.
on_signal() { trap '' INT TERM; echo "!!! $1"; kill -TERM 0 2>/dev/null; exit "$2"; }
trap 'on_signal interrupted 130' INT
trap 'on_signal terminated 143' TERM
run() { "$@" & wait $!; }
# Background watchdog: a full disk corrupts the tree and can take the host down with it.
( while sleep 60; do
      if [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; then
          echo "!!! Free space below ${MIN_FREE_GB} GB - aborting the build."
          kill -TERM 0
      fi
  done ) &
check_space

# 1. Manifest. Re-run every time so a changed BRANCH really switches the tree.
#    darwin/mips prebuilts are not needed on Linux and cost ~20 GB.
# 2. Sync with retries (one flaky fetch should not throw away hours of work).
#    An interrupted sync leaves traps for the next one: a project whose first fetch did
#    not finish has no `shallow` file, so repo takes it for a manually unshallowed clone
#    and fetches its complete history; a project whose checkout did not finish has HEAD
#    at the right revision, so repo skips it and leaves a half-empty worktree. Remove
#    such projects (repo re-creates them) and the locks and temporary packs of the
#    killed git processes. Nothing else may use the tree while build.sh runs.
clean_interrupted_sync() {
    local g wt
    [ -d .repo/projects ] && [ -d .repo/project-objects ] || return 0
    find .repo/projects .repo/project-objects -type f \
        \( -name '*.lock' -o -name 'tmp_pack_*' -o -name 'tmp_idx_*' \) -delete
    while IFS= read -r -d '' g; do
        wt="${g#.repo/projects/}"; wt="${wt%.git}"
        if [ ! -e "$g/shallow" ] && [ -z "$(git --git-dir="$g" for-each-ref --count=1)" ]; then
            echo ">>> ${wt}: first fetch was interrupted, re-cloning"
            rm -rf "$g"
            if [ -L "$wt/.git" ]; then rm "$wt/.git"; fi
        elif [ ! -e "$g/index" ] && [ -L "$wt/.git" ]; then
            echo ">>> ${wt}: checkout was interrupted, checking out again"
            rm "$wt/.git"
        fi
    done < <(find .repo/projects -type d -name '*.git' -prune -print0)
}
sync_tree() {
    local attempt=1
    echo ">>> repo init ${BRANCH}"
    repo init -u https://github.com/LineageOS/android.git -b "$BRANCH" --git-lfs --depth=1 \
        -g default,-darwin,-mips,-notdefault
    mkdir -p .repo/local_manifests
    cp "$REPO/manifests/treble-${BRANCH}.xml" .repo/local_manifests/treble.xml
    # A fetch whose connection stays open while the server sends nothing would hang
    # forever (seen with googlesource); let git abort it so repo retries the project.
    export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
    export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-600}"
    echo ">>> repo sync"
    while :; do
        clean_interrupted_sync
        run repo sync -c -j"$SYNC_JOBS" --fail-fast --force-sync --no-clone-bundle --no-tags \
            --retry-fetches=5 && break
        check_space
        if [ "$attempt" -ge "$SYNC_RETRIES" ]; then
            echo "!!! repo sync failed ${SYNC_RETRIES} times - giving up."
            exit 1
        fi
        echo ">>> repo sync failed (attempt ${attempt}/${SYNC_RETRIES}), retrying in $(( attempt * 30 ))s"
        run sleep $(( attempt * 30 ))
        attempt=$(( attempt + 1 ))
    done
    repo manifest -r -o "$LOG_DIR/manifest-$(date -u +%Y%m%d-%H%M%S).xml"
}
if [ "$SKIP_SYNC" = "true" ]; then
    echo ">>> SKIP_SYNC=true - building the tree as it is"
else
    sync_tree
fi
check_space

# 3. Patches, per project in this order: TrebleDroid's and MisterZtr's own from the
#    LineageOS_gsi project (directories named like platform_frameworks_base), then ours
#    from patches/<BRANCH>/<project path>/. patches/<BRANCH>/skip lists upstream patches
#    to leave out, one "trebledroid|trebledroid-staging|personal/<directory>/<file>" per line.
#    With DEBUG_PATCHES=true, patches/<BRANCH>-debug/ comes last: diagnostic changes that
#    must never be in a published build (e.g. no reboot when the eBPF loader fails).
#    Each patched project is reset to its manifest revision (m/<BRANCH>) and the patches
#    are applied with `git am`, so the result does not depend on what a previous run left
#    behind. A patch LineageOS has meanwhile merged is skipped (it reverse-applies);
#    any other failure stops the build. A marker in the project's .git skips projects
#    already in exactly this state.
GSI_PATCHES="$TOP/LineageOS_gsi/patches"
OWN_PATCHES="$REPO/patches/${BRANCH}"
declare -A PROJECT_PATCHES=()
gsi_project_path() {  # the mapping of LineageOS_gsi's apply-patches.sh
    local p; p="$(tr _ / <<<"$1" | sed -e 's;platform/;;g')"
    case "$p" in
        build) p=build/make ;;
        testing) p=platform_testing ;;
        vendor/hardware/overlay) p=vendor/hardware_overlay ;;
        treble/app) p=treble_app ;;
        vendor/partner/gms) p=vendor/partner_gms ;;
    esac
    echo "$p"
}
collect_patches() {
    local set dir project f
    for set in trebledroid trebledroid-staging personal; do
        for dir in "$GSI_PATCHES/$set"/*/; do
            dir="${dir%/}"
            project=$(gsi_project_path "$(basename "$dir")")
            for f in "$dir"/*.patch; do
                [ -e "$f" ] || continue
                if grep -qxF "$set/$(basename "$dir")/$(basename "$f")" "$OWN_PATCHES/skip" 2>/dev/null; then
                    echo ">>> Skipping $set/$(basename "$dir")/$(basename "$f") (patches/${BRANCH}/skip)"
                    continue
                fi
                PROJECT_PATCHES[$project]+="$f"$'\n'
            done
        done
    done
    local own dirs=("$OWN_PATCHES")
    [ "$DEBUG_PATCHES" = "true" ] && dirs+=("$OWN_PATCHES-debug")
    for own in "${dirs[@]}"; do
        [ -d "$own" ] || continue
        while IFS= read -r f; do
            project="${f#"$own"/}"; project="${project%/*}"
            PROJECT_PATCHES[$project]+="$f"$'\n'
        done < <(find "$own" -name '*.patch' | sort)
    done
}
apply_project() {  # <project>: patch files on stdin
    local project="$1" gitdir want old f mtimes patches=() applied=0 merged=0
    mapfile -t patches
    if [ "$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" != "$PWD/$project" ]; then
        echo "!!! Patches for ${project}, but the project is not in the tree."
        exit 1
    fi
    gitdir=$(git -C "$project" rev-parse --absolute-git-dir)
    want="$(cat "${patches[@]}" | sha256sum | cut -d' ' -f1) $(git -C "$project" rev-parse "m/${BRANCH}")"
    if [ "$(cat "$gitdir/applied-patches" 2>/dev/null)" = "$want $(git -C "$project" rev-parse HEAD)" ] \
        && [ -z "$(git -C "$project" status --porcelain)" ]; then
        return 0
    fi
    # Re-applying rewrites every patched file. Files whose content ends up unchanged get
    # their old mtime back, so one new patch does not make Soong and Kati re-read every
    # patched Android.bp/*.mk.
    old=$(git -C "$project" rev-parse HEAD)
    mtimes=()
    while IFS= read -r -d '' f; do
        if [ -e "$project/$f" ]; then mtimes+=("$(stat -c %Y "$project/$f") $f"); fi
    done < <(git -C "$project" diff -z --name-only "m/${BRANCH}" "$old")
    git -C "$project" am --abort >/dev/null 2>&1 || true
    git -C "$project" reset -q --hard "m/${BRANCH}"
    git -C "$project" clean -q -fd
    for f in "${patches[@]}"; do
        if git -C "$project" am -q --3way "$f" >/dev/null 2>&1; then
            applied=$(( applied + 1 ))
            continue
        fi
        git -C "$project" am --abort >/dev/null 2>&1 || true
        if git -C "$project" apply --reverse --check "$f" >/dev/null 2>&1; then
            echo "    already in ${BRANCH}: ${f#"$TOP"/}"
            merged=$(( merged + 1 ))
            continue
        fi
        echo "!!! ${f#"$TOP"/} does not apply to ${project}:"
        git -C "$project" apply --check "$f" 2>&1 | head -20 || true
        exit 1
    done
    echo ">>> Patched ${project}: ${applied} applied, ${merged} already merged"
    for f in "${mtimes[@]}"; do
        if git -C "$project" diff --quiet "$old" HEAD -- "${f#* }"; then
            touch -c -d "@${f%% *}" "$project/${f#* }"
        fi
    done
    echo "$want $(git -C "$project" rev-parse HEAD)" > "$gitdir/applied-patches"
}
collect_patches
# A project patched by an earlier run that has no patches left (e.g. all of them listed
# in skip) goes back to its manifest revision.
while IFS= read -r marker; do
    project="${marker#.repo/projects/}"; project="${project%.git/applied-patches}"
    [ -n "${PROJECT_PATCHES[$project]+x}" ] && continue
    echo ">>> Unpatching ${project} (no patches left)"
    git -C "$project" am --abort >/dev/null 2>&1 || true
    git -C "$project" reset -q --hard "m/${BRANCH}"
    rm -f "$marker"
done < <(find .repo/projects -name applied-patches -path '*.git/applied-patches' 2>/dev/null)
for project in $(printf '%s\n' "${!PROJECT_PATCHES[@]}" | sort); do
    printf '%s' "${PROJECT_PATCHES[$project]}" | apply_project "$project"
done

# TrebleDroid's boot script must still parse after the patches: a syntax error makes it
# die at that line at boot, silently skipping everything after it (seen with a patch
# applied to another TrebleDroid revision).
if ! bash -n device/phh/treble/rw-system.sh; then
    echo "!!! device/phh/treble/rw-system.sh has a syntax error after patching."
    exit 1
fi

if [ "$SYNC_ONLY" = "true" ]; then
    echo ">>> SYNC_ONLY=true - tree synced and patched, not building."
    exit 0
fi

# 4. Build. AOSP's shell tooling is not nounset-safe.
ccache -M "$CCACHE_SIZE" >/dev/null
set +u
source build/envsetup.sh
lunch "${TARGET}-${RELEASE}-${BUILD_TYPE}"
keep=(); [ "$KEEP_GOING" = "true" ] && keep=(-k)
# siso (the ninja replacement) leaves ~2 GB of logs per build in out/.
find out -maxdepth 1 -name 'siso.*.log.*' -delete 2>/dev/null || true
echo ">>> m ${keep[*]} systemimage simg2img -j${BUILD_JOBS}"
start=$(date +%s)
run m "${keep[@]}" systemimage simg2img -j"$BUILD_JOBS"
echo ">>> Build finished in $(( ($(date +%s) - start) / 60 )) min"

# 5. The image for the tablet: raw ext4 without the AVB footer (verification is disabled
#    on the tablet and the footer's hash tree costs ~40 MB of the tight super budget).
P80_OUT="$OUT/p80"
rm -rf "$P80_OUT"; mkdir -p "$P80_OUT"
suffix=""
# Test builds (root adb without authorization from the first boot) must not be published.
[ "${WITH_ADB_INSECURE:-}" = "true" ] && suffix="-adb-insecure"
[ "$DEBUG_PATCHES" = "true" ] && suffix="$suffix-debug"
img="$P80_OUT/system.img"
if [ "$(head -c 4 "$OUT/system.img" | od -An -tx4 | tr -d ' ')" = "ed26ff3a" ]; then
    "$TOP/out/host/linux-x86/bin/simg2img" "$OUT/system.img" "$img"
else
    cp "$OUT/system.img" "$img"
fi
if python3 external/avb/avbtool.py info_image --image "$img" >/dev/null 2>&1; then
    python3 external/avb/avbtool.py erase_footer --image "$img"
fi
size=$(stat -c %s "$img")
prop() {  # first value in the system, then the product build.prop (23.2 keeps the version there)
    local f
    # `sed -n 1p` reads to the end: `head -1` would close the pipe early, and the SIGPIPE
    # (with pipefail and set -e) ended the script silently before the budget check.
    for f in /system/build.prop /system/product/etc/build.prop; do
        debugfs -R "cat $f" "$img" 2>/dev/null | sed -n "s/^$1=//p"
    done | sed -n 1p
}
patch_level=$(prop ro.build.version.security_patch)
version=$(prop ro.lineage.version)
# Named like LineageOS's own files: lineage-23.2-<date>-UNOFFICIAL-P80.img
named="$P80_OUT/lineage-${version:-${BRANCH#lineage-}-$(date -u +%Y%m%d)}${suffix}.img"
mv "$img" "$named"; img="$named"
( cd "$P80_OUT" && sha256sum "$(basename "$img")" > SHA256SUMS )
echo ">>> ${img#"$TOP"/}: ${size} bytes, LineageOS ${version}, security patch ${patch_level}"
if [ "$size" -gt "$SUPER_BUDGET" ]; then
    echo "!!! The image is $(( (size - SUPER_BUDGET) / 1048576 + 1 )) MiB larger than the super budget (${SUPER_BUDGET} bytes)."
    exit 1
fi
echo ">>> Fits the super budget with $(( (SUPER_BUDGET - size) / 1048576 )) MiB to spare."
