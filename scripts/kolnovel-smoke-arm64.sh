#!/usr/bin/env bash
# Kolnovel mod smoke test: install, launch, screenshot, UI dump, crash scan.
# Adapted from the proven shareme-smoke.sh (install retry + package verify +
# fail-the-job-honestly on install failure; two capture rounds).
# App: com.benabdellah.KolNovelApp v83/5.2.5 (Expo/RN, Hermes).
# Note: merged universal APK, arm64-only .so files — the x86_64 emulator
# runs them via the system image's ARM translation (slow; allow long waits).
set -u
mkdir -p artifacts
APK="app/Kolnovel-v5.2.5-premium.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/com.benabdellah.KolNovelApp.MainActivity"

pull_retry() {
  local src="$1" dst="$2"
  local i
  for i in 1 2 3; do
    if adb pull "$src" "$dst" 2>&1 | tee -a artifacts/capture.log; then
      [ -s "$dst" ] && return 0
    fi
    echo "pull $src -> $dst attempt $i FAILED/empty, retrying" | tee -a artifacts/capture.log
    sleep 5
  done
  echo "pull $src -> $dst FAILED after 3 attempts" | tee -a artifacts/capture.log
  return 1
}

capture() {
  local tag="$1"
  echo "== capture $tag ==" | tee -a artifacts/capture.log
  adb exec-out screencap -p > "artifacts/${tag}.png" 2>>artifacts/capture.log || true
  if [ ! -s "artifacts/${tag}.png" ]; then
    echo "exec-out screencap empty for $tag, falling back to on-device file" | tee -a artifacts/capture.log
    adb shell screencap -p "/sdcard/${tag}.png" 2>>artifacts/capture.log || true
    pull_retry "/sdcard/${tag}.png" "artifacts/${tag}.png" || true
  fi
  adb shell uiautomator dump "/sdcard/ui-${tag}.xml" 2>>artifacts/capture.log || true
  pull_retry "/sdcard/ui-${tag}.xml" "artifacts/ui-${tag}.xml" || true
  if [ ! -s "artifacts/ui-${tag}.xml" ]; then
    sleep 5
    adb shell uiautomator dump "/sdcard/ui-${tag}.xml" 2>>artifacts/capture.log || true
    pull_retry "/sdcard/ui-${tag}.xml" "artifacts/ui-${tag}.xml" || true
  fi
  ls -la "artifacts/${tag}.png" "artifacts/ui-${tag}.xml" 2>&1 | tee -a artifacts/capture.log || true
}

echo "== installing APK =="
adb install -r "$APK" | tee artifacts/install.log
if ! grep -q "Success" artifacts/install.log; then
  echo "install attempt 1 did NOT report Success, waiting 30s and retrying once" | tee -a artifacts/install.log
  sleep 90
  adb install -r "$APK" | tee -a artifacts/install.log
fi
if ! adb shell pm list packages 2>/dev/null | grep -q "package:${PKG}$"; then
  echo "INSTALL FAILED (infra): ${PKG} not present after install attempts" | tee artifacts/verdict.txt
  adb logcat -d > artifacts/logcat.txt || true
  echo "== done (install failed, failing job honestly) =="
  ls -la artifacts/
  exit 1
fi
echo "install verified: ${PKG} present" | tee -a artifacts/install.log

echo "== launching $ACT =="
adb shell am start -n "$ACT"
sleep 90
capture home
adb shell input tap 325 1335 || true   # "Wait" on a "Process system isn't responding" ANR dialog, if present
sleep 5
echo "== foreground after 30s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee artifacts/foreground.txt || true
sleep 120
capture home2
echo "== foreground after 75s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee -a artifacts/foreground.txt || true

adb logcat -d > artifacts/logcat.txt || true

echo "== crash scan (app process only) =="
if awk '/FATAL EXCEPTION/{f=1; next} f==1 && /Process: com\.benabdellah\.KolNovelApp/{found=1; exit} f==1 && /FATAL EXCEPTION/{f=0} END{exit !found}' artifacts/logcat.txt; then
  echo "CRASH FOUND (com.benabdellah.KolNovelApp)" | tee artifacts/verdict.txt
  grep -A18 "FATAL EXCEPTION" artifacts/logcat.txt | grep -B2 -A15 "Process: com.benabdellah.KolNovelApp" | head -40 >> artifacts/verdict.txt
else
  echo "NO FATAL CRASH in logcat (com.benabdellah.KolNovelApp)" | tee -a artifacts/verdict.txt
fi
echo "== LVL check: no LicenseActivity / license error in logcat =="
grep -i "pairip\|LicenseClient\|LicenseActivity" artifacts/logcat.txt | head -20 | tee artifacts/lvl-lines.txt || true
echo "== done =="
ls -la artifacts/
