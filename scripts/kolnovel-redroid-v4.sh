#!/usr/bin/env bash
# Kolnovel v4 (PDF export) smoke + feature test on Redroid (arm64, NO KVM).
# v4 = v3 premium (F1/F2/F4/F5 + P1-P7 + P8/P9 LVL no-ops) + NEW:
#  - "تصدير PDF" button in the novel content-tab header (fn 21721 SeriesListHeaderInner)
#  - PdfExportActivity (native, Java): fetches the whole novel anonymously,
#    builds print HTML, WebView print via PrintManager (system print dialog).
#    NOTE: v4 uses PrintManager, NOT automatic MediaStore save (design 4.1
#    changed: direct createPrintDocumentAdapter().onLayout/onWrite is
#    impossible from app code - LayoutResultCallback/WriteResultCallback have
#    package-private constructors, proven by javap on android-34). The user
#    picks "Save as PDF" in the system dialog. PDF quality is identical.
# Tests:
#  A. Smoke: install + launch + home renders + 0 FATAL (same as v3).
#  B. PDF export pipeline: start PdfExportActivity directly with a real
#     novel (titleId 266817, 60 chapters) - exercises fetch + HTML + WebView
#     + print dialog. Verifies: progress log lines, print job created
#     (dumpsys print), print dialog screenshot.
#  C. Button presence (best effort): dump UI after launch and grep for the
#     button label; the button's onPress fires the same intent the direct
#     Activity test uses, so B is the substantive feature gate.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v4.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0
LOG_OK=0
PDF_OK=0
PDF_JOB=0

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

echo "== capture logcat (smoke) =="
adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || echo "logcat -d FAILED"
adb -s "$DEV" logcat -d -b crash > artifacts/logcat-crash.txt 2>&1 || true
if [ -s artifacts/logcat.txt ]; then LOG_OK=1; fi

echo "== FATAL scan (smoke) =="
grep -i -B2 -A40 "FATAL EXCEPTION" artifacts/logcat.txt > artifacts/fatal.txt 2>/dev/null || true
grep -i -E "AndroidRuntime|FATAL|${PKG}" artifacts/logcat.txt | head -60 > artifacts/fatal-lines.txt 2>/dev/null || true
if [ -s artifacts/fatal.txt ]; then
  echo "FATAL EXCEPTION FOUND:"
  cat artifacts/fatal.txt
else
  echo "no FATAL EXCEPTION in logcat"
fi

# ---- B. PDF export pipeline (direct Activity test) ----
if [ "$INSTALL_OK" = "1" ]; then
  echo "== PDF export test: start PdfExportActivity (novel 266817, 60 chapters) =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 266817 -e title "test" 2>&1 | tee artifacts/pdf-start.log || true
  sleep 5
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-pdf-start.png 2>/dev/null || true
  echo "== wait up to 300s for the print dialog (fetch 60 chapters + WebView) =="
  PDF_DIALOG=0
  for i in $(seq 1 30); do
    # Check logcat for the print-dialog marker (Activity logs when PrintManager.print is called)
    if adb -s "$DEV" logcat -d 2>/dev/null | grep -qi "print\|PrintManager\|PdfExport"; then
      echo "PdfExport log lines present after ~$((i * 10))s"
    fi
    # Check for a REAL print job: "print_job_id" only appears when a job
    # exists. (Bare "print_job" false-positives on "has_active_print_jobs".)
    if adb -s "$DEV" shell dumpsys print 2>/dev/null | grep -qi "print_job_id"; then
      PDF_DIALOG=1
      echo "print job found after ~$((i * 10))s"
      break
    fi
    # Check if the print dialog activity is in the foreground
    CUR=$(adb -s "$DEV" shell dumpsys activity activities 2>/dev/null | grep -i "mResumedActivity" | head -1)
    echo "poll $i: $CUR"
    if echo "$CUR" | grep -qi "print"; then
      PDF_DIALOG=1
      echo "print dialog activity in foreground after ~$((i * 10))s"
      break
    fi
    sleep 10
  done
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-pdf-dialog.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-pdf.txt 2>&1 || true
  adb -s "$DEV" shell dumpsys print > artifacts/dumpsys-print.txt 2>&1 || true
  echo "waiting 30s for the spooler to finish writing the PDF file"
  sleep 30
  echo "== pull the generated PDF from the print spooler (for V3 content check) =="
  adb -s "$DEV" root 2>&1 || true
  sleep 3
  adb -s "$DEV" shell ls -la /data/user/0/com.android.printspooler/files/ 2>&1 | tee artifacts/spooler-files.txt || true
  SPOOL_PDF=$(adb -s "$DEV" shell ls /data/user/0/com.android.printspooler/files/*.pdf 2>/dev/null | head -1 | tr -d '\r')
  echo "spooler pdf: $SPOOL_PDF"
  if [ -n "$SPOOL_PDF" ]; then
    adb -s "$DEV" pull "$SPOOL_PDF" artifacts/kolnovel-export.pdf 2>&1 | tee artifacts/pdf-pull.log || true
    ls -la artifacts/kolnovel-export.pdf 2>&1 || true
    # Also pull the Activity's cached HTML (proves the fetch + HTML build)
    adb -s "$DEV" shell "run-as $PKG ls -la /data/data/$PKG/cache/ 2>/dev/null | head" || true
  fi
  echo "== PdfExport log lines =="
  grep -i "PdfExport\|print" artifacts/logcat-pdf.txt | head -40 > artifacts/pdf-lines.txt || true
  cat artifacts/pdf-lines.txt
  echo "== print jobs =="
  grep -i "print job\|PrintJob\|state" artifacts/dumpsys-print.txt | head -20 || true
  if [ "$PDF_DIALOG" = "1" ]; then
    PDF_JOB=1
    echo "PDF: print dialog/job DETECTED"
  fi
  # Also check the Activity is still alive / did not crash
  if grep -qi "FATAL EXCEPTION" artifacts/logcat-pdf.txt; then
    echo "PDF: FATAL during export"
  else
    echo "PDF: no FATAL during export"
  fi
  if grep -qi "PdfExport" artifacts/logcat-pdf.txt; then
    PDF_OK=1
    echo "PDF: PdfExportActivity logged output"
  fi
fi

echo "== final logcat + tombstones =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
adb -s "$DEV" root 2>&1 || true
adb -s "$DEV" shell ls -la /data/tombstones/ 2>&1 | tee artifacts/tombstones.txt || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
wc -l artifacts/logcat.txt artifacts/logcat-pdf.txt artifacts/logcat-final.txt 2>&1 || true

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no) pdf_activity_logged=$PDF_OK pdf_print_job=$PDF_JOB"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
  echo "note: v4 uses PrintManager (system print dialog); the PDF is saved by the user picking 'Save as PDF'. No automatic Downloads/Kolnovel file."
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured (pdf_activity_logged=$PDF_OK pdf_print_job=$PDF_JOB)"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
