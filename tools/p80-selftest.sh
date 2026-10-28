#!/bin/bash
# Self-test of a LineageOS GSI build on the Teclast P80 (G3M2) over adb.
# Usage: tools/p80-selftest.sh [--reboot]
#   --reboot  also reboot the tablet, time the boot and repeat the boot health checks
# Prints PASS/FAIL/WARN/INFO per check and exits with the number of failures.
# Needs adb access; checks that need root are skipped unless "adb root" works
# (Developer options -> Rooted debugging, or a WITH_ADB_INSECURE build).
set -uo pipefail

ADB="${ADB:-adb}"
FAILS=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }
info() { printf '  INFO  %s\n' "$*"; }
sh() { $ADB shell "$@" 2>/dev/null | tr -d '\r'; }
prop() { sh getprop "$1"; }
expect_prop() {  # <prop> <expected> [description]
    local v; v=$(prop "$1")
    if [ "$v" = "$2" ]; then pass "${3:-$1} = $v"; else fail "${3:-$1} = '$v' (expected '$2')"; fi
}
section() { printf '\n== %s\n' "$*"; }

wait_boot() {
    local i
    for i in $(seq 1 120); do
        [ "$(prop sys.boot_completed)" = "1" ] && return 0
        sleep 5
    done
    return 1
}

ui_dump() {  # dumps the current UI hierarchy to stdout
    sh uiautomator dump /sdcard/p80-ui.xml >/dev/null
    sh cat /sdcard/p80-ui.xml
    sh rm -f /sdcard/p80-ui.xml
}

$ADB wait-for-device
if ! wait_boot; then echo "boot did not complete"; exit 1; fi
$ADB root >/dev/null 2>&1; sleep 3; $ADB wait-for-device
ROOT=false; [ "$(sh id -u)" = "0" ] && ROOT=true

section "Build"
info "LineageOS $(prop ro.lineage.version), Android $(prop ro.build.version.release), security patch $(prop ro.build.version.security_patch)"
expect_prop ro.product.model P80 "model"
expect_prop ro.product.brand Teclast "brand"
expect_prop ro.product.manufacturer Teclast "manufacturer"
expect_prop ro.build.characteristics tablet "characteristics"
[ "$(sh getenforce)" = "Enforcing" ] && pass "SELinux enforcing" || fail "SELinux $(sh getenforce)"
expect_prop ro.control_privapp_permissions enforce "privapp permissions"
if [ "$(prop ro.adb.secure)" = "1" ]; then pass "adb requires authorization"; else warn "adb without authorization (test build, never publish)"; fi

section "Boot health"
r=$(sh 'getprop | grep -E "init.svc.*restarting"'); [ -z "$r" ] && pass "no service restarting" || fail "restarting: $r"
c=$(sh 'logcat -b crash -d' | grep -E ">>> " | sed -E 's/.*>>> (.*) <<<.*/\1/' | sort | uniq -c | tr '\n' ';')
[ -z "$c" ] && pass "crash buffer empty" || fail "crashes: $c"
w=$(sh 'logcat -d -b all' | grep -c "WATCHDOG KILLING")
[ "$w" = "0" ] && pass "no system_server watchdog kill" || fail "$w watchdog kills"
b=$(sh 'logcat -d -b all' | grep -c "blocked syscall")
[ "$b" = "0" ] && pass "no seccomp-blocked syscalls" || fail "$b seccomp-blocked syscalls"
if sh 'mount' | grep -q "configstore@1.1.policy"; then pass "configstore seccomp policy patched"; else warn "configstore policy not bind-mounted"; fi
if sh 'grep -c 720p /vendor/etc/media_profiles_V1_0.xml' | grep -q '^[1-9]'; then pass "720p camcorder profile active"; else fail "no 720p camcorder profile"; fi

section "Wi-Fi-only tablet, no leftovers"
n=$(sh 'pm list features' | grep -c -E "telephony|fingerprint|nfc")
[ "$n" = "0" ] && pass "no telephony/fingerprint/NFC features" || fail "$n telephony/fingerprint/NFC features declared"
p=$(sh 'pm list packages' | sed 's/package://' | grep -x -E "me.phh.treble.app|com.android.dialer|com.android.messaging|com.android.stk|com.android.systemui.plugin.globalactions.wallet|me.phh.qcrilam" | tr '\n' ' ')
[ -z "$p" ] && pass "no TrebleApp, phone, SIM toolkit or wallet apps" || fail "still installed: $p"
expect_prop ro.tether.denied true "tethering disabled"
modes=$(sh 'cmd overlay lookup android android:array/config_availableColorModes' | grep -c .)
[ "$modes" = "0" ] && pass "no display color modes" || fail "$modes display color modes available"
night=$(sh 'cmd overlay lookup android android:bool/config_nightDisplayAvailable' | tail -1 | grep -o -E "true|false")
[ "$night" = "false" ] && pass "Night Light unavailable" || fail "Night Light available"
dim=$(sh 'cmd overlay lookup android android:bool/config_reduceBrightColorsAvailable' | tail -1 | grep -o -E "true|false")
[ "$dim" = "false" ] && pass "extra dim unavailable" || fail "extra dim available"

section "Settings and quick settings (UI)"
sh am start -a android.settings.DISPLAY_SETTINGS >/dev/null; sleep 3
x=$(ui_dump)
# the list is longer than the screen: look at its lower part too
sh input swipe 400 1000 400 300 300; sleep 2
x="$x$(ui_dump)"
for t in "Colors" "Night Light" "Extra dim"; do
    if printf '%s' "$x" | grep -q "text=\"$t\""; then fail "Display settings show '$t'"; else pass "Display settings without '$t'"; fi
done
sh am start -a android.settings.DEVICE_INFO_SETTINGS >/dev/null; sleep 3
x=$(ui_dump)
printf '%s' "$x" | grep -q 'TrebleDroid' && fail "About tablet mentions TrebleDroid" || pass "About tablet without TrebleDroid"
sh input keyevent KEYCODE_HOME; sleep 1
sh cmd statusbar expand-settings; sleep 3
x=$(ui_dump)
for t in "Wallet" "Hotspot" "Night Light"; do
    if printf '%s' "$x" | grep -q -i "content-desc=\"$t\|text=\"$t\""; then fail "quick settings show '$t'"; else pass "quick settings without '$t'"; fi
done
printf '%s' "$x" | grep -q -i "SIM" && fail "quick settings mention a SIM" || pass "no SIM in quick settings"
sh cmd statusbar collapse

section "Graphics"
gles=$(sh 'dumpsys SurfaceFlinger' | grep -m1 "^GLES:")
case "$gles" in *GE8300*) pass "${gles#GLES: }" ;; *) fail "GPU: $gles" ;; esac
sh svc power stayon usb; sh input keyevent KEYCODE_WAKEUP; sleep 1
sh am start -a android.settings.SETTINGS >/dev/null; sleep 3
sh input swipe 400 900 400 500 300; sleep 1
sf=$(sh 'dumpsys SurfaceFlinger')
cm=$(printf '%s' "$sf" | grep -m1 -o "colorTransformMatrix=\[\[[0-9.,-]*\]" )
case "$cm" in *"1.000,0.000,0.000,0.000"*) pass "identity color matrix" ;; *) fail "color matrix $cm" ;; esac
cl=$(printf '%s' "$sf" | grep -o -E "\| +(CLIENT|DEVICE) +\|" | tr -d '| ' | sort | uniq -c | tr '\n' ' ')
case "$cl" in *CLIENT*) fail "GPU composition in use: $cl" ;; *) pass "hardware composition: $cl" ;; esac

section "Performance"
# The 4.9 kernel has no userfaultfd: code compiled for the userfaultfd GC is rejected by ART.
expect_prop ro.dalvik.vm.enable_uffd_gc false "ART code compiled for the concurrent copying GC"
if $ROOT; then
    n=$(sh 'ls /data/misc/apexdata/com.android.art/dalvik-cache/arm64/' | grep -c -E "\.(art|odex)$")
    [ "$n" = "0" ] && pass "boot image and system_server code from /system" || fail "odrefresh recompiled $n boot/system_server files on the tablet"
fi
# The stock firmware's memory settings (per-app memcg soft limits swap the launcher out on 4.9)
expect_prop ro.config.per_app_memcg false "no per-app memory cgroups"
expect_prop ro.lmk.critical_upgrade true "lmkd critical upgrade"
expect_prop dalvik.vm.heapgrowthlimit 128m "app heap growth limit"
for pkg in com.android.launcher3 com.android.settings com.android.systemui org.lineageos.setupwizard; do
    st=$(sh "dumpsys package dexopt" | grep -A4 "^  \[$pkg\]" | grep -m1 -o "status=[a-z-]*\] \[reason=[a-z-]*" | tr -d '[]')
    case "$st" in status=speed*) pass "$pkg $st" ;; *) warn "$pkg ${st:-not found}" ;; esac
done
sh am force-stop com.android.settings
t=$(sh am start -W -a android.settings.SETTINGS | grep -o "TotalTime: [0-9]*")
info "Settings cold start: ${t#TotalTime: } ms"
sh dumpsys gfxinfo com.android.settings reset >/dev/null
for i in 1 2 3 4 5; do sh input swipe 400 1000 400 300 200; sh input swipe 400 300 400 1000 200; done
j=$(sh dumpsys gfxinfo com.android.settings | grep -m1 "Janky frames:")
info "Settings scrolling: ${j# *}"
info "memory available: $(sh 'grep MemAvailable /proc/meminfo' | tr -s ' ' | cut -d' ' -f2) kB"
$ROOT && info "memory pressure: $(sh 'cat /proc/pressure/memory' | tr '\n' ' ')"
sh svc power stayon false

section "Radios and media"
w=$(sh 'dumpsys wifi' | grep -m1 "^mWifiInfo" | grep -o -E "Supplicant state: [A-Z_]+|Frequency: [0-9]+MHz|Link speed: [0-9-]+Mbps" | tr '\n' ' ')
case "$w" in *COMPLETED*) pass "Wi-Fi connected: $w" ;; *) warn "Wi-Fi not connected: $w" ;; esac
if sh 'ping -c 3 -W 3 1.1.1.1' | grep -q " 0% packet loss"; then pass "internet reachable"; else warn "ping 1.1.1.1 failed"; fi
if sh 'ping -c 1 -W 3 lineageos.org' | grep -q "1 received"; then pass "DNS works"; else warn "DNS lookup failed"; fi
for i in 1 2; do sh svc bluetooth disable; sleep 4; sh svc bluetooth enable; sleep 8; done
bt=$(sh 'dumpsys bluetooth_manager' | grep -m1 "^  state:" | tr -s ' ')
case "$bt" in *ON*) pass "Bluetooth on after 2 off/on cycles" ;; *) fail "Bluetooth$bt" ;; esac
nc=$(sh 'logcat -b crash -d' | grep -c ">>> com.android.bluetooth")
[ "$nc" = "0" ] && pass "Bluetooth did not crash" || fail "Bluetooth crashed $nc times"
s=$(sh 'service list' | grep -c -E "media.audio_(flinger|policy)")
[ "$s" = "2" ] && pass "audio services up" || fail "audio services: $s/2"
cams=$(sh 'dumpsys media.camera' | grep -m1 "Number of camera devices" | grep -o "[0-9]*$")
[ "$cams" = "2" ] && pass "2 cameras" || fail "cameras: $cams"
if sh 'logcat -d -b all' | grep -q "IOmx service obtained"; then pass "vendor OMX codecs in use"
elif sh 'dumpsys media.player' | grep -q '"OMX.allwinner.video.decoder.avc"'; then pass "vendor OMX decoders registered (no video played since boot)"
else fail "vendor OMX decoders missing from the codec list"; fi
sh 'dumpsys sensorservice' | grep -q -i "accelerometer" && pass "accelerometer present" || fail "no accelerometer"

section "Battery"
info "$(sh 'dumpsys battery' | grep -E "level|temperature|status" | tr -s ' ' | tr '\n' ' ')"

if [ "${1:-}" = "--reboot" ]; then
    section "Reboot"
    s=$(date +%s); $ADB reboot; sleep 20; $ADB wait-for-device
    if wait_boot; then pass "boot completed in $(( $(date +%s) - s )) s"; else fail "no boot completion"; fi
    $ADB root >/dev/null 2>&1; sleep 3; $ADB wait-for-device
    c=$(sh 'logcat -b crash -d' | grep -c ">>> ")
    [ "$c" = "0" ] && pass "no crashes after reboot" || fail "$c crashes after reboot"
fi

printf '\n%s failure(s)\n' "$FAILS"
exit "$FAILS"
