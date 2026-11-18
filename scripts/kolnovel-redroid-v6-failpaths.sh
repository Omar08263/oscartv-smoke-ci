#!/usr/bin/env bash
# Kolnovel v6 - V6 failure-path test on Redroid (arm64, NO KVM) — problem 2.
# Tests that a failed export FAILS CLEANLY: error toast, NO print job,
# NO partial/truncated PDF, NO crash, Activity finishes.
#  Case A: bogus titleId (999999999) -> reading-list 404 -> clean error.
#  Case B: real novel 76237 (401 ch, fetch takes ~30-60 s) + airplane mode
#          at +8 s after start -> network dies MID-FETCH -> clean error.
#  (Case C, a real server 500 mid-fetch, is the separate mitm500 run:
#  scripts/kolnovel-redroid-v6-mitm500.sh — a proxy returning HTTP 500 for
#  /reader/* after the 3rd request.)
# The v5 APK is under test (the Activity is unchanged from v5 unless the
# v6 build modifies it — then this run is repeated with the v6 APK).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v5.apk"
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

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 30

check_clean() { # $1 = case tag; expects: no print job, no PDF, no FATAL, app alive
  local tag="$1"
  adb -s "$DEV" shell dumpsys print > "artifacts/dumpsys-$tag.txt" 2>&1 || true
  if grep -qi "print_job_id" "artifacts/dumpsys-$tag.txt" 2>/dev/null; then
    echo "$tag: PRINT JOB EXISTS (BAD)"
    echo "${tag}_print_job=YES" >> artifacts/RESULT.md
  else
    echo "$tag: no print job (GOOD)"
    echo "${tag}_print_job=NO" >> artifacts/RESULT.md
  fi
  local pdfs
  pdfs=$(adb -s "$DEV" shell "ls /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null" | tr -d '\r')
  if [ -n "$pdfs" ]; then
    echo "$tag: PDF FILE EXISTS (BAD): $pdfs"
    echo "${tag}_pdf=YES" >> artifacts/RESULT.md
  else
    echo "$tag: no PDF file (GOOD)"
    echo "${tag}_pdf=NO" >> artifacts/RESULT.md
  fi
  if grep -qi "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-$tag.txt" 2>/dev/null; then
    echo "$tag: FATAL/SIGSEGV found (BAD)"
    echo "${tag}_fatal=YES" >> artifacts/RESULT.md
  else
    echo "$tag: no FATAL (GOOD)"
    echo "${tag}_fatal=NO" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
    echo "$tag: app process alive (GOOD)"
  else
    echo "$tag: app process GONE (BAD — the export must fail, not kill the app)"
    echo "${tag}_app_gone=YES" >> artifacts/RESULT.md
  fi
  # Is the export Activity gone (finished) rather than stuck on screen?
  adb -s "$DEV" shell dumpsys activity activities 2>/dev/null \
    | grep -m1 -i "PdfExportActivity" > "artifacts/top-$tag.txt" || true
  if grep -qi "PdfExportActivity" "artifacts/top-$tag.txt" 2>/dev/null; then
    echo "$tag: PdfExportActivity still on top (STUCK?)"
  else
    echo "$tag: PdfExportActivity finished (GOOD)"
  fi
}

# ---- Case A: bogus titleId -> 404 -> clean error, no print job ----
if [ "$INSTALL_OK" = "1" ]; then
  echo "== V6 Case A: bogus titleId 999999999 (expect clean error, NO print job) =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 999999999 -e title "bogus" 2>&1 | tee artifacts/caseA-start.log || true
  sleep 25
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseA.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseA.txt 2>&1 || true
  check_clean "caseA"
fi

# ---- Case B: real titleId, airplane mode mid-fetch ----
if [ "$INSTALL_OK" = "1" ]; then
  echo "== V6 Case B: real novel 76237 (401 ch) + airplane mode at +8s =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 76237 -e title "test" 2>&1 | tee artifacts/caseB-start.log || true
  sleep 8
  echo "enabling airplane mode now (fetch should be in progress)"
  adb -s "$DEV" shell settings put global airplane_mode_on 1 2>&1 || true
  adb -s "$DEV" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>&1 || true
  adb -s "$DEV" shell settings get global airplane_mode_on 2>&1 | tee artifacts/airplane-state.txt || true
  sleep 45
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseB.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseB.txt 2>&1 || true
  check_clean "caseB"
  # Restore network
  adb -s "$DEV" shell settings put global airplane_mode_on 0 2>&1 || true
  adb -s "$DEV" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>&1 || true
  sleep 5
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
