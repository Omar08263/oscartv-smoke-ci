#!/usr/bin/env bash
# OscarTV mod smoke test: install, launch, screenshot, UI dump,
# best-effort profile/ad-free navigation + premium text check, crash scan.
# v2: two capture rounds (25s + 60s) + foreground-activity record, so a slow
# first load still yields evidence; all captures best-effort, never fail job.
set -u
mkdir -p artifacts
APK="app/OscarTV-v1.1.6-premium-v13.apk"
PKG="com.drama.mp4"
ACT="com.drama.mp4/com.drama.mp4.ui.splash.SplashActivity"

# v13-r2: pull failures are retried SEPARATELY from dump failures.
# (v13 run 43431636163: the on-device dump succeeded but `adb pull`
# silently failed, so artifacts had no screenshots/dumps at all.)
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
  # screenshot straight to host (no on-device file + pull round-trip)
  adb exec-out screencap -p > "artifacts/${tag}.png" 2>>artifacts/capture.log || true
  if [ ! -s "artifacts/${tag}.png" ]; then
    echo "exec-out screencap empty for $tag, falling back to on-device file" | tee -a artifacts/capture.log
    adb shell screencap -p "/sdcard/${tag}.png" 2>>artifacts/capture.log || true
    pull_retry "/sdcard/${tag}.png" "artifacts/${tag}.png" || true
  fi
  adb shell uiautomator dump "/sdcard/ui-${tag}.xml" 2>>artifacts/capture.log || true
  pull_retry "/sdcard/ui-${tag}.xml" "artifacts/ui-${tag}.xml" || true
  # retry the UI dump once if the pull produced nothing
  if [ ! -s "artifacts/ui-${tag}.xml" ]; then
    sleep 5
    adb shell uiautomator dump "/sdcard/ui-${tag}.xml" 2>>artifacts/capture.log || true
    pull_retry "/sdcard/ui-${tag}.xml" "artifacts/ui-${tag}.xml" || true
  fi
  ls -la "artifacts/${tag}.png" "artifacts/ui-${tag}.xml" 2>&1 | tee -a artifacts/capture.log || true
}

echo "== installing APK =="
adb install -r "$APK" | tee artifacts/install.log

echo "== launching $ACT =="
adb shell am start -n "$ACT"
sleep 25
capture home
echo "== foreground after 25s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee artifacts/foreground.txt || true
sleep 35
capture home2
echo "== foreground after 60s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee -a artifacts/foreground.txt || true

echo "== v13: tap a movie detail, capture [D7] screen (best effort) =="
python3 scripts/tap_detail.py || true

adb logcat -d > artifacts/logcat.txt || true

echo "== profile/ad-free navigation + premium check (best effort) =="
python3 scripts/check_premium.py || true

echo "== crash scan (app process only) =="
# A FATAL EXCEPTION belongs to our app only if the following line says
# "Process: com.drama.mp4" (the process name is on the NEXT line).
if awk '/FATAL EXCEPTION/{f=1; next} f==1 && /Process: com\.drama\.mp4/{found=1; exit} f==1 && /FATAL EXCEPTION/{f=0} END{exit !found}' artifacts/logcat.txt; then
  echo "CRASH FOUND (com.drama.mp4)" | tee artifacts/verdict.txt
  grep -A18 "FATAL EXCEPTION" artifacts/logcat.txt | grep -B2 -A15 "Process: com.drama.mp4" | head -40 >> artifacts/verdict.txt
else
  echo "NO FATAL CRASH in logcat (com.drama.mp4)" | tee -a artifacts/verdict.txt
fi
echo "== done =="
ls -la artifacts/
