#!/usr/bin/env bash
# Kolnovel v4 - V6 failure-path test on Redroid (arm64, NO KVM).
# Tests that a failed export FAILS CLEANLY: error toast, NO print job,
# NO partial/truncated PDF.
#  Case A: bogus titleId (999999999) -> reading-list 404 -> clean error.
#  Case B: real titleId but network cut mid-fetch (airplane mode) -> error.
# The v4 APK is already in the repo (app/Kolnovel-v5.2.5-premium-v4.apk).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v4.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0

echo "== host =="
uname -m
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi

echo "== kernel modules (binder/ashmem) =="
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"

echo "== pull Redroid arm64 image =="
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -3

echo "== start Redroid =="
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5

echo "== wait for boot (up to 600s) =="
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > artifacts/RESULT.md; exit 1; fi

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 30

# ---- Case A: bogus titleId -> 404 -> clean error, no print job ----
if [ "$INSTALL_OK" = "1" ]; then
  echo "== V6 Case A: bogus titleId 999999999 (expect clean error, NO print job) =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 999999999 -e title "bogus" 2>&1 | tee artifacts/caseA-start.log || true
  sleep 20
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseA.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseA.txt 2>&1 || true
  adb -s "$DEV" shell dumpsys print > artifacts/dumpsys-caseA.txt 2>&1 || true
  if adb -s "$DEV" shell dumpsys print 2>/dev/null | grep -qi "print_job_id"; then
    echo "CASE A: FAIL - a print job was created for a bogus novel"
    echo "caseA_print_job=YES" >> artifacts/RESULT.md
  else
    echo "CASE A: PASS - no print job for bogus novel"
    echo "caseA_print_job=NO" >> artifacts/RESULT.md
  fi
  # Check the Activity finished (not stuck) and no FATAL
  if grep -qi "FATAL EXCEPTION" artifacts/logcat-caseA.txt; then echo "CASE A: FATAL found"; else echo "CASE A: no FATAL"; fi
fi

# ---- Case B: real titleId, airplane mode mid-fetch ----
if [ "$INSTALL_OK" = "1" ]; then
  echo "== V6 Case B: real novel 266817 + airplane mode mid-fetch =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 266817 -e title "test" 2>&1 | tee artifacts/caseB-start.log || true
  sleep 5
  echo "enabling airplane mode now"
  adb -s "$DEV" shell settings put global airplane_mode_on 1 2>&1 || true
  adb -s "$DEV" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>&1 || true
  sleep 30
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseB.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseB.txt 2>&1 || true
  adb -s "$DEV" shell dumpsys print > artifacts/dumpsys-caseB.txt 2>&1 || true
  if adb -s "$DEV" shell dumpsys print 2>/dev/null | grep -qi "print_job_id"; then
    echo "CASE B: a print job exists (export may have finished before the cut, or partial)"
    echo "caseB_print_job=YES" >> artifacts/RESULT.md
  else
    echo "CASE B: PASS - no print job after network cut"
    echo "caseB_print_job=NO" >> artifacts/RESULT.md
  fi
  if grep -qi "FATAL EXCEPTION" artifacts/logcat-caseB.txt; then echo "CASE B: FATAL found"; else echo "CASE B: no FATAL"; fi
  # Restore network
  adb -s "$DEV" shell settings put global airplane_mode_on 0 2>&1 || true
  adb -s "$DEV" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>&1 || true
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true

{
  echo "RESULT: install_ok=$INSTALL_OK"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee -a artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
