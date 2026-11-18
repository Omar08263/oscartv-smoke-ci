#!/usr/bin/env bash
# Kolnovel v6 FINAL - Crash-flake A/B (problem 3 FIX, round 3): v3 vs v6c.
# v6c bundle fix: colors from the FUNCTION PROPS (r19) only — the v6b
# Mov-r0 stash broke it deterministically (4/4 RangeError: r0 is `this`,
# never a scratch register). Details still from items[0].props.
# v6b bundle fix: colors/details are read from the FUNCTION PROPS (r19/r0
# stash), NOT re-derived from items[0].props — v6 (bundle-a) crashed 1/4
# with TypeError "Cannot read property onSurfaceVariant of undefined"
# (items[0].props.colors was undefined in cycle 4).
# Question: does the detail-open SIGSEGV/TypeError follow OUR patched header
# (fn 21721 SeriesListHeaderInner, v4/v5) or is it stock/environment flake?
# Method: install v3 (stock header, NO button patch) and v5 (patched header),
# tap the SAME middle cover (novel 76237, 401 ch — home feed is identical
# across runs, proven from ui-home.xml) 4 times each, and count crashes.
# A crash = the app process dies (pidof empty) within ~15 s of the tap, or a
# FATAL EXCEPTION / SIGSEGV appears in logcat. Detail-open success = the
# novel title appears in a UI dump after the tap.
# NOTE: this script does NOT export anything — it only opens the detail.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
NOVEL_TITLE="جمر الليل الأبدي"

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
}
tap_text() {
  local needle="$1" f="artifacts/ui-current.xml"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-current.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-current.xml "$f" 2>/dev/null
  local bounds
  bounds=$(python3 - "$f" "$needle" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
f, needle = sys.argv[1], sys.argv[2]
try: root = ET.parse(f).getroot()
except Exception: sys.exit(1)
for node in root.iter('node'):
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if needle in t or needle in cd:
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print((x1+x2)//2, (y1+y2)//2); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  adb -s "$DEV" shell input tap $bounds 2>&1
  return 0
}
alive() { adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; }
crash_type() {
  local f="$1"
  if grep -q "Fatal signal 11" "$f" 2>/dev/null; then echo "SIGSEGV"; return; fi
  if grep -q "FATAL EXCEPTION" "$f" 2>/dev/null; then echo "FATAL-EXC"; return; fi
  echo "unknown"
}

echo "== host =="
uname -m
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -3
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > artifacts/RESULT.md; exit 1; fi

test_apk() { # $1 = apk path in repo, $2 = tag (v3/v5)
  local apk="$1" tag="$2"
  echo "########## testing $tag ($apk) ##########"
  adb -s "$DEV" shell pm clear "$PKG" 2>/dev/null || true
  adb -s "$DEV" install -r -g "$apk" 2>&1 | tee "artifacts/install-$tag.log"
  if ! grep -q "Success" "artifacts/install-$tag.log"; then
    echo "$tag: INSTALL FAILED"; echo "$tag crashes=INSTALL-FAIL" >> artifacts/RESULT.md; return
  fi
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee "artifacts/launch-$tag.log" || true
  sleep 15
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$tag-launch.png" 2>/dev/null || true
  dump_ui "$tag-launch"
  tap_text "Consent" || tap_text "consent" || echo "$tag: no Consent button"
  sleep 5
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || echo "$tag: no skip/next"
  sleep 5
  dump_ui "$tag-home"
  local crashes=0 oks=0 misses=0
  for cycle in 1 2 3 4; do
    echo "== $tag cycle $cycle: tap middle cover (360,750) =="
    adb -s "$DEV" logcat -c 2>&1 || true
    adb -s "$DEV" shell input tap 360 750 2>&1 || true
    sleep 12
    adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-c$cycle.txt" 2>&1 || true
    adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$tag-c$cycle.png" 2>/dev/null || true
    dump_ui "$tag-c$cycle"
    if ! alive; then
      crashes=$((crashes + 1))
      echo "$tag cycle $cycle: CRASH ($(crash_type "artifacts/logcat-$tag-c$cycle.txt"))"
      grep -i -A 25 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-$tag-c$cycle.txt" \
        > "artifacts/crash-$tag-c$cycle.txt" 2>/dev/null || true
      # relaunch for the next cycle
      adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee -a "artifacts/launch-$tag.log" || true
      sleep 15
      dump_ui "$tag-relaunch-c$cycle"
      tap_text "Consent" || true; sleep 3
      tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || true; sleep 5
      continue
    fi
    if grep -q "$NOVEL_TITLE" "artifacts/ui-$tag-c$cycle.xml" 2>/dev/null; then
      oks=$((oks + 1))
      echo "$tag cycle $cycle: DETAIL OK (title present)"
    else
      misses=$((misses + 1))
      echo "$tag cycle $cycle: ALIVE but detail title NOT in UI dump (miss or slow load)"
    fi
    adb -s "$DEV" shell input keyevent 4 2>&1 || true
    sleep 5
  done
  echo "$tag: crashes=$crashes detail_ok=$oks alive_no_detail=$misses / 4 cycles" | tee -a artifacts/RESULT.md
}

test_apk "app/Kolnovel-v5.2.5-premium-v3.apk" "v3"
test_apk "app/Kolnovel-v5.2.5-premium-v6.apk" "v6"

adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE"
cat artifacts/RESULT.md
