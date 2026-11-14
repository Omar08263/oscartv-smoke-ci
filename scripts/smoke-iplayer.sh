#!/usr/bin/env bash
# iPlayer mod smoke test: install, launch, screenshot, UI dump,
# VIP/premium text check, crash scan.
# Adapted from scripts/smoke.sh (OscarTV). All captures best-effort, never fail job.
# NOTE: emulator is google_apis (no Play Store), so Play Billing never connects;
# the mod's VIP default (key_prefs_vip=TRUE) is what makes VIP true at first launch.
set -u
mkdir -p artifacts
APK="app/iPlayer-v2.8.2-premium.apk"
PKG="iplayer.and.new.com"
ACT="iplayer.and.new.com/com.ipbox.player.app.act.LpSplashActivity"

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
echo "install exit: ${PIPESTATUS[0]}" | tee -a artifacts/install.log
adb shell pm list packages | grep -i "iplayer" | tee -a artifacts/install.log || true

echo "== launching $ACT =="
adb shell am start -n "$ACT"
sleep 25
capture home
echo "== foreground after 25s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee artifacts/foreground.txt || true
# If the app is not in the foreground (e.g. a system ANR dialog stole focus),
# dismiss any ANR dialog and retry the launch once.
if ! grep -q "iplayer.and.new.com" artifacts/foreground.txt; then
  echo "== app not in foreground, dismissing dialogs + relaunching ==" | tee -a artifacts/foreground.txt
  adb shell input keyevent KEYCODE_BACK || true
  adb shell am start -n "$ACT" || true
  sleep 15
  adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee -a artifacts/foreground.txt || true
fi
sleep 35
capture home2
echo "== foreground after 60s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee -a artifacts/foreground.txt || true

adb logcat -d > artifacts/logcat.txt || true

echo "== VIP / premium text check (best effort) =="
# VIP badge / premium strings in the dumped UI hierarchy, if the main UI rendered.
grep -i -o "vip[^\"<]*\|premium[^\"<]*" artifacts/ui-home.xml artifacts/ui-home2.xml 2>/dev/null | sort -u | tee artifacts/vip-text.txt || true
if [ -s artifacts/vip-text.txt ]; then
  echo "VIP/PREMIUM TEXT FOUND in UI dump" | tee artifacts/verdict.txt
else
  echo "no VIP/premium text in UI dumps (inconclusive: UI may not have rendered)" | tee artifacts/verdict.txt
fi

echo "== crash scan (app process only) =="
# A FATAL EXCEPTION belongs to our app only if the following line says
# "Process: iplayer.and.new.com".
if awk '/FATAL EXCEPTION/{f=1; next} f==1 && /Process: iplayer\.and\.new\.com/{found=1; exit} f==1 && /FATAL EXCEPTION/{f=0} END{exit !found}' artifacts/logcat.txt; then
  echo "CRASH FOUND (iplayer.and.new.com)" | tee -a artifacts/verdict.txt
  grep -A18 "FATAL EXCEPTION" artifacts/logcat.txt | grep -B2 -A15 "Process: iplayer.and.new.com" | head -40 >> artifacts/verdict.txt
else
  echo "NO FATAL CRASH in logcat (iplayer.and.new.com)" | tee -a artifacts/verdict.txt
fi
echo "== done =="
ls -la artifacts/
