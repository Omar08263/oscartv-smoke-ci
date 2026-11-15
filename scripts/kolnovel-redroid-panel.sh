#!/usr/bin/env bash
# Kolnovel mod smoke test on Redroid (arm64 Android userspace, NO KVM).
# Why Redroid: the APK is arm64-v8a ONLY (30 native libs, no x86_64).
# - x86_64 emulator: install OK but SoLoader fails loading arm64 .so -> does
#   NOT reproduce the real on-device crash (proven dead, runs 43607122588 /
#   43609822383).
# - arm64-v8a SDK emulator on x86_64 host (TCG, no KVM): never boots in a
#   usable time (run 43612078938 FAILED at the emulator step).
# - GitHub ubuntu-24.04-arm runners have NO /dev/kvm either, so the SDK
#   emulator cannot accelerate there. Redroid runs the Android userspace
#   directly on the host kernel via binder/ashmem (no QEMU, no KVM) and its
#   arm64 image executes natively on the ARM host: real arm64 .so loading,
#   real Hermes/SoLoader init — the closest CI approximation of Omar's phone.
# App: com.benabdellah.KolNovelApp v83/5.2.5, MainActivity
# .MainActivity, v3 sha256 4488b494194f12200229f3364fdc226a51f355f9ae49a4e41a7b1d8d36112592.
# v2 fixes the crash v1 died on: 73 apktool-lost @null drawable refs restored
# (abc_switch_thumb_material + abc_btn_check_material + 71 more), incl. the
# splash icon (D1). All 7 Hermes premium patches + LVL no-ops unchanged.
# v3 (2026-11-15): logged-out premium manifest — F1 premium initial store state, F4 account panel on hasActiveSubscription, F5 free downloads always allowed, F2 refreshRoleBenefits survives the HTTP-500 throw. F3 (ad-policy) skipped: getter/installer bodies are shared with 1117/6 functions. All 7 round-1 patches + LVL no-ops unchanged.
# PANEL VARIANT of kolnovel-redroid (v3): same install+launch+logcat proof, PLUS
# best-effort tap navigation (uiautomator, text-driven) to the Account screen
# to capture the F4 ReadingAccountPanel (اشتراك سنوي / مشترك نشط) logged out.
# Taps are best-effort: every step screenshots + dumps UI, so a missed tap is
# diagnosable from the artifacts instead of silently passing.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v3.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
INSTALL_OK=0
# --- tap helpers (panel navigation) ---
cat > /tmp/tap.py <<'PYEOF'
import sys, re
import xml.etree.ElementTree as ET
# usage: tap.py <ui.xml> <text1> [<text2> ...] -> prints "X Y" of first clickable
# node whose text/content-desc contains any of the texts (exact-substring match).
xml, texts = sys.argv[1], sys.argv[2:]
try:
    root = ET.parse(xml).getroot()
except Exception as e:
    print(f"XML parse fail: {e}", file=sys.stderr); sys.exit(1)
best = None
for node in root.iter('node'):
    t = (node.get('text') or '') + '|' + (node.get('content-desc') or '')
    if not any(x in t for x in texts):
        continue
    b = node.get('bounds') or ''
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    clickable = node.get('clickable') == 'true'
    cand = ((0 if clickable else 1), (x2 - x1) * (y2 - y1), (x1 + x2) // 2, (y1 + y2) // 2)
    if best is None or cand[:2] < best[:2]:
        best = cand
if best is None:
    sys.exit(1)
print(f"{best[2]} {best[3]}")
PYEOF
dump_ui() { # $1 = out name; retries until the dump is non-empty (uiautomator
  # can return an empty file while the window is still settling)
  local i
  for i in 1 2 3; do
    adb -s "$DEV" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb -s "$DEV" pull /sdcard/ui.xml "artifacts/$1" >/dev/null 2>&1
    if [ -s "artifacts/$1" ] && grep -q "<hierarchy" "artifacts/$1" 2>/dev/null; then
      echo "ui dump $1 OK (try $i)"
      return 0
    fi
    echo "ui dump $1 empty/bad, retry $i"
    sleep 3
  done
  echo "ui dump $1 FAILED after retries"
  ls -la "artifacts/$1" 2>&1 || true
}
tap_text() { # $1 = xml file, $2.. = texts to try (first match wins)
  local xml="$1"; shift
  local xy
  xy=$(python3 /tmp/tap.py "artifacts/$xml" "$@" 2>/dev/null) || return 1
  echo "tap $xy for text [$*] in $xml"
  adb -s "$DEV" shell input tap $xy
}
shoot() { # $1 = out name
  adb -s "$DEV" exec-out screencap -p > "artifacts/$1" 2>/dev/null || echo "screencap $1 FAILED"
  ls -la "artifacts/$1" 2>&1 || true
}
LOG_OK=0

echo "== host =="
uname -m
nproc; free -h | head -2
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
adb --version | head -1 || echo "adb STILL MISSING"

echo "== kernel modules (binder/ashmem) =="
ls /dev/binder* /dev/ashmem 2>&1 || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder_linux modprobe FAILED (may be built-in or absent)"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem_linux modprobe FAILED (may be built-in or absent)"
ls -l /dev/binder* /dev/ashmem 2>&1 || echo "NO binder/ashmem devices after modprobe"

echo "== pull Redroid arm64 image =="
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -5
docker image inspect redroid/redroid:13.0.0-latest --format '{{.Architecture}} {{.Os}}' 2>&1

echo "== start Redroid =="
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
echo "device mounts:$MOUNTS"
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
docker ps --filter name=redroid --format '{{.Status}} {{.Image}}' 2>&1
docker logs redroid 2>&1 | tail -20 || true

echo "== wait for adb + boot_completed (up to 600s) =="
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then
  echo "REDROID DID NOT BOOT in 600s"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  adb -s "$DEV" shell getprop 2>&1 | head -20 || true
  echo "RESULT: REDROID_BOOT_FAILED" > artifacts/RESULT.md
  exit 1
fi

echo "== device identity (must be arm64) =="
adb -s "$DEV" shell getprop ro.product.cpu.abi
adb -s "$DEV" shell getprop ro.build.version.release
adb -s "$DEV" shell getprop ro.product.model
adb -s "$DEV" shell uname -m

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if ! grep -q "Success" artifacts/install.log; then
  echo "install attempt 1 failed, retrying once after 30s"
  sleep 30
  adb -s "$DEV" install -r -g "$APK" 2>&1 | tee -a artifacts/install.log
fi
if grep -q "Success" artifacts/install.log; then
  INSTALL_OK=1
  echo "INSTALL: SUCCESS"
else
  echo "INSTALL: FAILED"
fi
adb -s "$DEV" shell pm path "$PKG" 2>&1 | tee -a artifacts/install.log || true
adb -s "$DEV" shell dumpsys package "$PKG" 2>/dev/null | grep -E "versionCode|versionName" | head -3 || true

if [ "$INSTALL_OK" = "1" ]; then
  echo "== launch MainActivity =="
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
  echo "== wait 60s for the crash to happen =="
  sleep 60
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 60s (crashed or exited)"
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-60s.png 2>/dev/null || true
  ls -la artifacts/screen-60s.png 2>&1 || true
fi

echo "== panel navigation: consent first, then skip onboarding -> Settings -> Account =="
# ORDER MATTERS (learned from runs 43676859007 / 43677339368): the UMP consent
# dialog is up at 60s and blocks the onboarding skip — dismiss it FIRST, then
# skip. Consent is checked on EVERY dump (a dump can come back empty while
# the window settles). Every tap reads a FRESH dump; each step verifies the
# screen actually changed before proceeding.
dismiss_consent() { # $1 = dump file; taps Consent if present, returns 0 if tapped
  if grep -qi "Consent" "artifacts/$1" 2>/dev/null; then
    echo "UMP consent dialog detected in $1, tapping Consent"
    tap_text "$1" "Consent" || adb -s "$DEV" shell input tap 360 955
    sleep 5
    return 0
  fi
  return 1
}
dump_ui ui1.xml
if dismiss_consent ui1.xml; then shoot screen-after-consent.png; dump_ui ui1b.xml; dismiss_consent ui1b.xml || true; fi
dump_ui ui2.xml
dismiss_consent ui2.xml && { shoot screen-after-consent.png; dump_ui ui2b.xml; cp artifacts/ui2b.xml artifacts/ui2.xml; }
tap_text ui2.xml "تخطي" || { echo "skip text not found, fallback tap 635 125"; adb -s "$DEV" shell input tap 635 125; }
sleep 8
shoot screen-after-skip.png
dump_ui ui3.xml
dismiss_consent ui3.xml && { dump_ui ui3b.xml; cp artifacts/ui3b.xml artifacts/ui3.xml; }
if grep -q "تخطي" artifacts/ui3.xml; then
  echo "onboarding still present, retrying skip"
  tap_text ui3.xml "تخطي" || adb -s "$DEV" shell input tap 635 125
  sleep 8
  shoot screen-after-skip2.png
  dump_ui ui3b.xml
  cp artifacts/ui3b.xml artifacts/ui3.xml
fi
# Home screen should now be showing; go to the Settings tab.
if grep -q "الإعدادات" artifacts/ui3.xml; then
  tap_text ui3.xml "الإعدادات" || { echo "settings tab tap failed, fallback 72 1180"; adb -s "$DEV" shell input tap 72 1180; }
  sleep 8
  shoot screen-settings.png
  dump_ui ui4.xml
else
  echo "NOT ON HOME SCREEN after skip (ui3 has no tab bar) — aborting nav"
  cp artifacts/ui3.xml artifacts/ui4.xml
fi
# Account row only if we are actually on Settings (accounts section present).
if grep -q "الحسابات" artifacts/ui4.xml; then
  tap_text ui4.xml "حساب القراءة" "مستخدم" "تسجيل الدخول" || echo "NO account-row match in settings UI"
  sleep 8
  shoot screen-account.png
  dump_ui ui5.xml
  if grep -q "حساب القراءة" artifacts/ui5.xml; then
    echo "reading tab visible, tapping it"
    tap_text ui5.xml "حساب القراءة" || true
    sleep 5
    shoot screen-account-reading.png
    dump_ui ui6.xml
  fi
else
  echo "NOT ON SETTINGS (ui4 has no accounts section) — aborting nav"
fi
adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after navigation"

echo "== capture logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || echo "logcat -d FAILED"
adb -s "$DEV" logcat -d -b crash > artifacts/logcat-crash.txt 2>&1 || true
adb -s "$DEV" root 2>&1 || true
adb -s "$DEV" shell ls -la /data/tombstones/ 2>&1 | tee artifacts/tombstones.txt || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
if [ -s artifacts/logcat.txt ]; then LOG_OK=1; fi
wc -l artifacts/logcat.txt artifacts/logcat-crash.txt 2>&1 || true

echo "== FATAL scan =="
grep -i -B2 -A40 "FATAL EXCEPTION" artifacts/logcat.txt > artifacts/fatal.txt 2>/dev/null || true
grep -i -E "AndroidRuntime|FATAL|${PKG}" artifacts/logcat.txt | head -60 > artifacts/fatal-lines.txt 2>/dev/null || true
if [ -s artifacts/fatal.txt ]; then
  echo "FATAL EXCEPTION FOUND:"
  cat artifacts/fatal.txt
else
  echo "no FATAL EXCEPTION in logcat"
fi

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no)"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
