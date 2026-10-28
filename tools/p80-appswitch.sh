#!/bin/bash
# App-switching memory test for the Teclast P80 over adb: launches a fixed set of apps in
# rounds, going home between them, and reports how each launch started (COLD/WARM/HOT) and
# how long it took, plus the reclaim work of the kernel and lmkd during the test.
# Usage: tools/p80-appswitch.sh [rounds]   (default 2; needs adb root for the kernel counters)
# Run it right after a reboot or framework restart so runs start from the same state.
set -uo pipefail

ADB="${ADB:-adb}"
ROUNDS="${1:-2}"
URL="https://en.m.wikipedia.org/wiki/Android_(operating_system)"
APPS=(
    com.android.settings/.Settings
    org.lineageos.jelly/.MainActivity
    org.lineageos.aperture/.CameraLauncher
    com.android.deskclock/.DeskClock
    com.android.calculator2/.Calculator
    com.android.documentsui/.LauncherActivity
    org.lineageos.glimpse/.MainActivity
    org.lineageos.etar/com.android.calendar.AllInOneActivity
)
sh() { $ADB shell "$@" 2>/dev/null | tr -d '\r'; }

# kswapd CPU ticks, pgmajfault, pswpin, pswpout, PSI memory some/full totals (us)
snapshot() {
    sh 'k=$(ps -A -o PID,NAME | grep -w kswapd0 | tr -s " " | sed "s/^ //" | cut -d" " -f1)
        set -- $(cut -d" " -f14,15 /proc/$k/stat)
        echo $(( $1 + $2 )) $(awk "/^pgmajfault /{m=\$2} /^pswpin /{i=\$2} /^pswpout /{o=\$2} END{print m, i, o}" /proc/vmstat) \
             $(sed -n "s/.*total=//p" /proc/pressure/memory)'
}
anrs() { sh 'dumpsys dropbox' | grep -c -E "(data|system)_app_anr"; }

$ADB root >/dev/null 2>&1; $ADB wait-for-device
sh svc power stayon usb; sh input keyevent KEYCODE_WAKEUP; sh wm dismiss-keyguard; sleep 1
sh input keyevent KEYCODE_HOME; sleep 2
t0=$(sh date +"%m-%d %H:%M:%S.000")
read -r k0 mf0 si0 so0 ps0 pf0 <<<"$(snapshot)"
a0=$(anrs)

for r in $(seq 1 "$ROUNDS"); do
    printf '\n== round %s\n' "$r"
    cold=0; warm=0; hot=0; timeouts=0; total=0
    for app in "${APPS[@]}"; do
        if [ "${app%%/*}" = org.lineageos.jelly ]; then
            out=$(sh "am start -W -a android.intent.action.VIEW -d '$URL' -n $app")
        else
            out=$(sh am start -W -n "$app")
        fi
        st=$(printf '%s' "$out" | sed -n 's/^LaunchState: //p')
        tt=$(printf '%s' "$out" | sed -n 's/^TotalTime: //p')
        # no first frame within am's limit: count the time am waited
        if printf '%s' "$out" | grep -q "^Status: timeout"; then
            st=TIMEOUT; tt=$(printf '%s' "$out" | sed -n 's/^WaitTime: //p'); timeouts=$((timeouts + 1))
        fi
        printf '  %-8s %6s ms  %s\n' "${st:-?}" "${tt:-?}" "${app%%/*}"
        case "$st" in COLD) cold=$((cold + 1)) ;; WARM) warm=$((warm + 1)) ;; HOT) hot=$((hot + 1)) ;; esac
        total=$((total + ${tt:-0}))
        sleep 3; sh input keyevent KEYCODE_HOME; sleep 2
    done
    printf '  round %s: %s cold, %s warm, %s hot, %s timeouts, %s ms in total\n' "$r" "$cold" "$warm" "$hot" "$timeouts" "$total"
done

read -r k1 mf1 si1 so1 ps1 pf1 <<<"$(snapshot)"
printf '\n== reclaim during the test\n'
printf '  kswapd0 CPU: %s s\n' "$(( (k1 - k0) / 100 ))"
printf '  major page faults: %s, pages swapped in: %s, out: %s\n' "$((mf1 - mf0))" "$((si1 - si0))" "$((so1 - so0))"
printf '  memory PSI: some %s ms, full %s ms\n' "$(( (ps1 - ps0) / 1000 ))" "$(( (pf1 - pf0) / 1000 ))"
kills=$(sh "logcat -d -b main,system -T '$t0'" | sed -n -E "s/.*lowmemorykiller: Kill '([^']*)'.*oom_score_adj ([0-9-]+).*/\1 (\2)/p")
printf '  lmkd kills: %s%s\n' "$(printf '%s' "$kills" | grep -c .)" "$(printf '%s' "$kills" | sed 's/^/; /' | tr -d '\n')"
printf '  new ANRs: %s\n' "$(( $(anrs) - a0 ))"
printf '  memory available now: %s kB\n' "$(sh 'grep MemAvailable /proc/meminfo' | tr -s ' ' | cut -d' ' -f2)"
sh svc power stayon false
