#!/usr/bin/env bash
# ShareMe mod smoke test: install, launch, screenshot, UI dump,
# best-effort send/receive navigation + ad-activity scan, crash scan.
# Adapted from the proven OscarTV smoke.sh (v13-r2 capture hardening).
# Re-run note (2026-11-13): first run 43438116721 failed on infra only —
# runner had no KVM permission, emulator never booted in 600s.
# Boot timeout bumped to 900s in the workflow as insurance.
# Run 2 (43440854551) "succeeded" vacuously: boot took 893s (no KVM),
# system_server then crashed in a loop, install failed "Broken pipe",
# launch "Can't find service: activity", screenshots pure black, zero
# midrop lines in logcat — the app never ran. Script now retries the
# install once, verifies the package, and exits 1 honestly on failure.
# Two capture rounds (25s + 60s) + foreground-activity record, so a slow
# first load still yields evidence; all captures best-effort, never fail job.
set -u
mkdir -p artifacts
APK="app/ShareMe-v3.48.05-premium.apk"
PKG="com.xiaomi.midrop"
ACT="com.xiaomi.midrop/com.xiaomi.midrop.SplashScreen"

# pull failures are retried SEPARATELY from dump failures.
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
# Run-2 lesson (43440854551): install FAILED with
# "Failure calling service package: Broken pipe (32)" because
# system_server was in a crash loop right after the slow no-KVM boot —
# and the script still reported job SUCCESS with a vacuous
# "NO FATAL CRASH" (the app had never run). Fix: retry once, verify the
# package is really present, and FAIL THE JOB honestly if it is not.
if ! grep -q "Success" artifacts/install.log; then
  echo "install attempt 1 did NOT report Success, waiting 30s and retrying once" | tee -a artifacts/install.log
  sleep 30
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
sleep 25
capture home
echo "== foreground after 25s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee artifacts/foreground.txt || true
sleep 35
capture home2
echo "== foreground after 60s =="
adb shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity\|mFocusedApp" | head -4 | tee -a artifacts/foreground.txt || true

adb logcat -d > artifacts/logcat.txt || true

echo "== send/receive navigation + ad-activity scan (best effort) =="
python3 scripts/check_shareme.py || true

echo "== crash scan (app process only) =="
# A FATAL EXCEPTION belongs to our app only if the following line says
# "Process: com.xiaomi.midrop" (the process name is on the NEXT line).
if awk '/FATAL EXCEPTION/{f=1; next} f==1 && /Process: com\.xiaomi\.midrop/{found=1; exit} f==1 && /FATAL EXCEPTION/{f=0} END{exit !found}' artifacts/logcat.txt; then
  echo "CRASH FOUND (com.xiaomi.midrop)" | tee artifacts/verdict.txt
  grep -A18 "FATAL EXCEPTION" artifacts/logcat.txt | grep -B2 -A15 "Process: com.xiaomi.midrop" | head -40 >> artifacts/verdict.txt
else
  echo "NO FATAL CRASH in logcat (com.xiaomi.midrop)" | tee -a artifacts/verdict.txt
fi
echo "== done =="
ls -la artifacts/
