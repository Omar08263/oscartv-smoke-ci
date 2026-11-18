#!/usr/bin/env bash
# Kolnovel v6 - Big-novel stress test on Redroid (arm64, NO KVM) — problem 1 (V4).
# Target: novel 38916 «القس المجنون», 2,355 chapters (live chapter_count,
# verified 2026-11-18 from the API; the max in probe data).
# The novel is NOT on the home feed, so the export is launched DIRECTLY via
# the kexport:// deep link (the button->Activity handoff is already proven
# in v4/v5; this run tests the EXPORT PIPELINE: fetch 2,355 chapters ->
# build ~33 MB HTML -> WebView layout -> print -> save -> pull).
# Success = a pulled PDF with page count ~= chapters + cover/TOC and all
# headings in order (checked offline after the run, not by this script).
# Failure modes recorded with evidence: OOM (logcat onTrimMemory / RSS /
# renderer death), timeout (no dialog in 40 min), crash (FATAL/SIGSEGV).
# If the single job fails, the v6 fix is the §4.3 part-split fallback.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v5.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
TITLE_ID=38916
INSTALL_OK=0
DIALOG=0
PDF_SAVED=0

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
mem_snapshot() { # $1 = tag
  {
    echo "=== mem $1 $(date -u +%H:%M:%S) ==="
    adb -s "$DEV" shell dumpsys meminfo "$PKG" 2>/dev/null | grep -E "TOTAL|Java Heap|Native Heap" | head -5
    adb -s "$DEV" shell cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemFree|MemAvailable"
    adb -s "$DEV" shell ps -A -o RSS,NAME 2>/dev/null | grep -iE "kolnovel|webview|printspooler" | head -8
  } >> artifacts/mem.log 2>&1 || true
}

echo "== host =="
uname -m; nproc; free -h | head -2
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

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15
adb -s "$DEV" exec-out screencap -p > artifacts/screen-launch.png 2>/dev/null || true

if [ "$INSTALL_OK" = "1" ]; then
  echo "== dismiss consent / skip onboarding =="
  dump_ui launch
  tap_text "Consent" || tap_text "consent" || echo "no Consent button"
  sleep 5
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || echo "no skip/next"
  sleep 5
  mem_snapshot "post-launch"

  echo "== launch export directly: kexport://$TITLE_ID =="
  START_TS=$(date +%s)
  echo "export_started_at_epoch=$START_TS" > artifacts/timing.txt
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://$TITLE_ID" 2>&1 | tee artifacts/deeplink.log || true
  sleep 10
  adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
  if ! grep -qi "PdfExportActivity" artifacts/logcat-afterstart.txt; then
    echo "deep link did NOT start PdfExportActivity; fallback: extras launch"
    adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId "$TITLE_ID" 2>&1 | tee artifacts/extras-launch.log || true
    sleep 10
    adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
  fi
  if grep -qi "PdfExportActivity" artifacts/logcat-afterstart.txt; then
    echo "PdfExportActivity STARTED"
  else
    echo "PdfExportActivity NEVER started — aborting"
    echo "RESULT: install_ok=$INSTALL_OK activity_started=0" | tee artifacts/RESULT.md
    docker rm -f redroid >/dev/null 2>&1 || true
    exit 1
  fi

  echo "== wait up to 40 min for the system print dialog (poll every 60s) =="
  for w in $(seq 1 40); do
    sleep 60
    dump_ui "printwait-$w" >/dev/null 2>&1
    if grep -qiE "Select a printer" "artifacts/ui-printwait-$w.xml" 2>/dev/null; then
      DIALOG=1
      DIALOG_TS=$(date +%s)
      echo "PRINT DIALOG APPEARED after ~$(( (DIALOG_TS - START_TS) / 60 )) min"
      echo "dialog_after_min=$(( (DIALOG_TS - START_TS) / 60 ))" >> artifacts/timing.txt
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-printdialog.png 2>/dev/null || true
      cp "artifacts/ui-printwait-$w.xml" artifacts/ui-printdialog.xml
      break
    fi
    # progress + liveness + memory every 5 min
    if [ $((w % 5)) = 0 ]; then
      echo "  waited $((w)) min, no dialog yet"
      adb -s "$DEV" shell pidof "$PKG" 2>/dev/null || echo "  APP PROCESS GONE at ${w}min!"
      mem_snapshot "wait-${w}min"
      adb -s "$DEV" logcat -d > artifacts/logcat-wait.txt 2>&1 || true
      grep -iE "FATAL|SIGSEGV|OutOfMemory|onTrimMemory" artifacts/logcat-wait.txt | head -5 || echo "  no fatal/oom markers"
      adb -s "$DEV" exec-out screencap -p > "artifacts/screen-wait-$w.png" 2>/dev/null || true
    fi
    if ! adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
      echo "APP DIED during export wait (minute $w)"
      adb -s "$DEV" logcat -d > artifacts/logcat-died.txt 2>&1 || true
      grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" artifacts/logcat-died.txt > artifacts/crash.txt 2>/dev/null || true
      mem_snapshot "died-${w}min"
      break
    fi
  done

  if [ "$DIALOG" = "1" ]; then
    echo "== pick Save as PDF from the printer dropdown =="
    tap_text "Select a printer" || echo "Select-a-printer tap failed"
    sleep 3
    dump_ui printpick >/dev/null 2>&1
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-printpick.png 2>/dev/null || true
    tap_text "Save as PDF" || echo "Save-as-PDF row tap failed"
    sleep 3
    dump_ui printdialog2 >/dev/null 2>&1
    echo "== poll up to 300s for the Save-to-PDF button (preview ready) =="
    SAVED_TAP=0
    for i in $(seq 1 60); do
      if tap_text "Save to PDF"; then SAVED_TAP=1; break; fi
      sleep 5
    done
    [ "$SAVED_TAP" = "1" ] || echo "Save-to-PDF button NEVER appeared"
    sleep 8
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-aftersave.png 2>/dev/null || true
    for s in $(seq 1 12); do
      dump_ui "aftersave-$s" >/dev/null 2>&1
      if grep -q 'text="SAVE"' "artifacts/ui-aftersave-$s.xml" 2>/dev/null; then
        echo "SAF save picker appeared; tapping SAVE"
        tap_text "SAVE" || echo "SAVE tap failed"
        sleep 5
        dump_ui aftersave2 >/dev/null 2>&1
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-aftersave2.png 2>/dev/null || true
        break
      fi
      sleep 5
    done
    echo "== look for a saved PDF (poll up to 300s) =="
    PDFFILE=""
    for p in $(seq 1 30); do
      PDFFILE=$(adb -s "$DEV" shell "ls -t /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null | head -1" | tr -d '
')
      if [ -n "$PDFFILE" ]; then echo "PDF appeared after ~$((p * 10))s: $PDFFILE"; break; fi
      sleep 10
    done
    if [ -n "$PDFFILE" ]; then
      LAST=-1; STABLE=0
      for w in $(seq 1 60); do
        SZ=$(adb -s "$DEV" shell "stat -c %s '$PDFFILE' 2>/dev/null" | tr -d '
')
        echo "size poll $w: ${SZ:-?}"
        if [ -n "$SZ" ] && [ "$SZ" -gt 0 ] 2>/dev/null && [ "$SZ" = "$LAST" ]; then STABLE=1; break; fi
        LAST="$SZ"
        sleep 10
      done
      [ "$STABLE" = "1" ] || echo "WARNING: size never stabilized (last=$LAST)"
    fi
    adb -s "$DEV" shell "ls -la /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null" | tee artifacts/pdflist.txt || true
    if [ -n "$PDFFILE" ]; then
      adb -s "$DEV" pull "$PDFFILE" artifacts/exported.pdf 2>&1 | tail -1
      if [ -s artifacts/exported.pdf ]; then
        PDF_SAVED=1; ls -la artifacts/exported.pdf
        SAVE_TS=$(date +%s); echo "saved_after_min=$(( (SAVE_TS - START_TS) / 60 ))" >> artifacts/timing.txt
      else echo "pulled PDF is EMPTY"; PDF_SAVED=0; fi
    else echo "NO PDF in Download"; fi
  else
    echo "PRINT DIALOG did NOT appear within 40 min"
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-noprintdialog.png 2>/dev/null || true
  fi
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
if grep -qi "FATAL EXCEPTION" artifacts/logcat-final.txt; then echo "FATAL found"; else echo "no FATAL"; fi
grep -ci "Fatal signal" artifacts/logcat-final.txt || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
{
  echo "RESULT: install_ok=$INSTALL_OK print_dialog=$DIALOG pdf_saved=$PDF_SAVED title_id=$TITLE_ID"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md
docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
