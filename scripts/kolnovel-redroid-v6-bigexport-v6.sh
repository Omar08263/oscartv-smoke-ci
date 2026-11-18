#!/usr/bin/env bash
# Kolnovel v6 FINAL - Big-novel stress + auto-save on Redroid (arm64, NO KVM).
# Problems 1 + 4 (V2): the v6 part-split (§4.3) + auto-save end-to-end.
# Phase 1: novel 38916 «القس المجنون», 2,355 chapters. The v6 Activity shows
# a part chooser (5 parts of <=500 ch); the script taps "الجزء 1" (ch 1-500),
# then waits for the PDF. With auto-save (v6) the PDF lands DIRECTLY in
# /sdcard/Download/Kolnovel/ (no dialog). If auto-save fails, the system
# print dialog appears instead (fallback) — the script then does the
# Save-as-PDF flow and pulls the PDF from Download/.
# Phase 2 (regression): novel 76237 (401 ch, <=500) — NO chooser must appear;
# the PDF must auto-save straight to Download/Kolnovel/.
# Success = a pulled PDF per phase with page count ~= chapters + cover/TOC
# and all headings in order (checked offline after the run, not here).
# Failure modes recorded with evidence: crash (FATAL/SIGSEGV in OUR app),
# renderer death (guard must turn it into a clean fail, not a SIGTRAP),
# timeout (no PDF and no dialog in 40 min).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0

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
# find_pdf: prints the newest PDF path in the auto-save dir or Download, else empty.
find_pdf() {
  adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n '
}
# wait_for_pdf_or_dialog $1=tag $2=max_minutes — sets WAIT_OUTCOME to
# autosave|dialog|died|timeout and WAIT_PDF to the pdf path (autosave case).
wait_for_pdf_or_dialog() {
  local tag="$1" maxmin="$2"
  WAIT_OUTCOME="timeout"; WAIT_PDF=""
  for w in $(seq 1 "$maxmin"); do
    sleep 60
    local p
    p=$(find_pdf)
    if [ -n "$p" ]; then
      WAIT_OUTCOME="autosave"; WAIT_PDF="$p"
      echo "[$tag] AUTO-SAVE PDF appeared after ~${w} min: $p"
      return 0
    fi
    dump_ui "${tag}-wait-$w" >/dev/null 2>&1
    if grep -qiE "Select a printer" "artifacts/ui-${tag}-wait-$w.xml" 2>/dev/null; then
      WAIT_OUTCOME="dialog"
      echo "[$tag] PRINT DIALOG appeared after ~${w} min (auto-save fell back)"
      adb -s "$DEV" exec-out screencap -p > "artifacts/screen-${tag}-printdialog.png" 2>/dev/null || true
      cp "artifacts/ui-${tag}-wait-$w.xml" "artifacts/ui-${tag}-printdialog.xml"
      return 0
    fi
    if [ $((w % 5)) = 0 ]; then
      echo "  [$tag] waited ${w} min, no PDF and no dialog yet"
      adb -s "$DEV" shell pidof "$PKG" 2>/dev/null || echo "  [$tag] APP PROCESS GONE at ${w}min!"
      mem_snapshot "${tag}-wait-${w}min"
      adb -s "$DEV" exec-out screencap -p > "artifacts/screen-${tag}-wait-$w.png" 2>/dev/null || true
    fi
    if ! adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
      WAIT_OUTCOME="died"
      echo "[$tag] APP DIED during export wait (minute $w)"
      adb -s "$DEV" logcat -d > "artifacts/logcat-${tag}-died.txt" 2>&1 || true
      grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-${tag}-died.txt" > "artifacts/crash-${tag}.txt" 2>/dev/null || true
      mem_snapshot "${tag}-died-${w}min"
      return 0
    fi
  done
  echo "[$tag] TIMEOUT after ${maxmin} min (no PDF, no dialog)"
}
# save_via_dialog $1=tag — the v4/v5 Save-as-PDF flow; sets DIALOG_PDF path.
save_via_dialog() {
  local tag="$1"
  DIALOG_PDF=""
  tap_text "Select a printer" || echo "Select-a-printer tap failed"
  sleep 3
  dump_ui "${tag}-printpick" >/dev/null 2>&1
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-${tag}-printpick.png" 2>/dev/null || true
  tap_text "Save as PDF" || echo "Save-as-PDF row tap failed"
  sleep 3
  dump_ui "${tag}-printdialog2" >/dev/null 2>&1
  local SAVED_TAP=0
  for i in $(seq 1 60); do
    if tap_text "Save to PDF"; then SAVED_TAP=1; break; fi
    sleep 5
  done
  [ "$SAVED_TAP" = "1" ] || echo "Save-to-PDF button NEVER appeared"
  sleep 8
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-${tag}-aftersave.png" 2>/dev/null || true
  for s in $(seq 1 12); do
    dump_ui "${tag}-aftersave-$s" >/dev/null 2>&1
    if grep -q 'text="SAVE"' "artifacts/ui-${tag}-aftersave-$s.xml" 2>/dev/null; then
      echo "SAF save picker appeared; tapping SAVE"
      tap_text "SAVE" || echo "SAVE tap failed"
      sleep 5
      dump_ui "${tag}-aftersave2" >/dev/null 2>&1
      adb -s "$DEV" exec-out screencap -p > "artifacts/screen-${tag}-aftersave2.png" 2>/dev/null || true
      break
    fi
    sleep 5
  done
  for p in $(seq 1 30); do
    DIALOG_PDF=$(find_pdf)
    if [ -n "$DIALOG_PDF" ]; then echo "PDF appeared after ~$((p * 10))s: $DIALOG_PDF"; break; fi
    sleep 10
  done
}
# pull_stable_pdf $1=remote_path $2=local_name — waits for a stable non-zero
# size, then pulls. Sets PULLED=1 on success.
pull_stable_pdf() {
  local remote="$1" localname="$2"
  PULLED=0
  [ -n "$remote" ] || { echo "pull: no remote path"; return 0; }
  local LAST=-1 STABLE=0
  for w in $(seq 1 60); do
    local SZ
    SZ=$(adb -s "$DEV" shell "stat -c %s '$remote' 2>/dev/null" | tr -d '\r\n ')
    echo "size poll $w: ${SZ:-?}"
    if [ -n "$SZ" ] && [ "$SZ" -gt 0 ] 2>/dev/null && [ "$SZ" = "$LAST" ]; then STABLE=1; break; fi
    LAST="$SZ"
    sleep 10
  done
  [ "$STABLE" = "1" ] || echo "WARNING: size never stabilized (last=$LAST)"
  adb -s "$DEV" pull "$remote" "artifacts/$localname" 2>&1 | tail -1
  if [ -s "artifacts/$localname" ]; then PULLED=1; ls -la "artifacts/$localname"; else echo "pulled PDF is EMPTY"; fi
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

echo "== install APK (v6) =="
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

  # ---------------- Phase 1: 38916 (2,355 ch) — part chooser + auto-save ----
  echo "== Phase 1: export 38916 via kexport:// deep link =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://38916" 2>&1 | tee artifacts/p1-deeplink.log || true
  sleep 10
  adb -s "$DEV" logcat -d > artifacts/logcat-p1-afterstart.txt 2>&1 || true
  if ! grep -qi "PdfExportActivity" artifacts/logcat-p1-afterstart.txt; then
    echo "deep link did NOT start PdfExportActivity; fallback: extras launch"
    adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 38916 2>&1 | tee artifacts/p1-extras-launch.log || true
    sleep 10
  fi
  echo "== wait up to 5 min for the part chooser =="
  CHOOSER=0
  for c in $(seq 1 10); do
    dump_ui "p1-chooser-$c" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-p1-chooser-$c.xml" 2>/dev/null; then
      CHOOSER=1
      echo "PART CHOOSER appeared after ~$((c * 30))s"
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-p1-chooser.png 2>/dev/null || true
      cp "artifacts/ui-p1-chooser-$c.xml" artifacts/ui-p1-chooser.xml
      break
    fi
    sleep 30
  done
  if [ "$CHOOSER" = "1" ]; then
    echo "== tap Part 1 (chapters 1-500) =="
    tap_text "الجزء 1" || echo "Part-1 tap FAILED"
    sleep 5
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-p1-after-parttap.png 2>/dev/null || true
  else
    echo "PART CHOOSER NEVER appeared (BAD for a 2,355-ch novel)"
  fi
  echo "== wait up to 40 min for the Part-1 PDF (auto-save) or the dialog =="
  wait_for_pdf_or_dialog "p1" 40
  P1_OUTCOME="$WAIT_OUTCOME"
  if [ "$P1_OUTCOME" = "autosave" ]; then
    pull_stable_pdf "$WAIT_PDF" "exported-p1.pdf"
    [ "$PULLED" = "1" ] && P1_OUTCOME="autosave-pdf"
  elif [ "$P1_OUTCOME" = "dialog" ]; then
    save_via_dialog "p1"
    pull_stable_pdf "$DIALOG_PDF" "exported-p1.pdf"
    [ "$PULLED" = "1" ] && P1_OUTCOME="dialog-pdf"
  fi
  echo "P1 outcome: $P1_OUTCOME" | tee -a artifacts/RESULT.md
  adb -s "$DEV" shell "ls -la /sdcard/Download/Kolnovel/ /sdcard/Download/*.pdf 2>/dev/null" | tee artifacts/pdflist-p1.txt || true

  # ---------------- Phase 2: 76237 (401 ch) — no chooser, auto-save --------
  echo "== Phase 2: export 76237 (401 ch) — regression, no chooser expected =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/p2-deeplink.log || true
  sleep 10
  echo "== wait up to 2 min: chooser must NOT appear for a 401-ch novel =="
  CHOOSER2=0
  for c in $(seq 1 4); do
    dump_ui "p2-chooser-$c" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-p2-chooser-$c.xml" 2>/dev/null; then
      CHOOSER2=1
      echo "CHOOSER APPEARED for 76237 (BAD — 401 ch needs no split)"
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-p2-chooser-bad.png 2>/dev/null || true
      break
    fi
    sleep 30
  done
  [ "$CHOOSER2" = "0" ] && echo "No chooser for 76237 (GOOD)"
  if [ "$CHOOSER2" = "1" ]; then tap_text "الجزء 1" || true; sleep 5; fi
  echo "== wait up to 20 min for the 76237 PDF (auto-save) or the dialog =="
  wait_for_pdf_or_dialog "p2" 20
  P2_OUTCOME="$WAIT_OUTCOME"
  if [ "$P2_OUTCOME" = "autosave" ]; then
    pull_stable_pdf "$WAIT_PDF" "exported-p2.pdf"
    [ "$PULLED" = "1" ] && P2_OUTCOME="autosave-pdf"
  elif [ "$P2_OUTCOME" = "dialog" ]; then
    save_via_dialog "p2"
    pull_stable_pdf "$DIALOG_PDF" "exported-p2.pdf"
    [ "$PULLED" = "1" ] && P2_OUTCOME="dialog-pdf"
  fi
  echo "P2 outcome: $P2_OUTCOME (chooser=$CHOOSER2)" | tee -a artifacts/RESULT.md
  adb -s "$DEV" shell "ls -la /sdcard/Download/Kolnovel/ /sdcard/Download/*.pdf 2>/dev/null" | tee artifacts/pdflist-p2.txt || true
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
# App-specific fatal scan (bluetooth SIGABRT tombstones are Redroid noise).
if grep -i "lah.KolNovelApp" artifacts/logcat-final.txt 2>/dev/null | grep -qi "Fatal signal\|FATAL EXCEPTION"; then
  echo "APP FATAL found (BAD)"; echo "app_fatal=YES" >> artifacts/RESULT.md
else
  echo "no APP FATAL (GOOD)"; echo "app_fatal=NO" >> artifacts/RESULT.md
fi
if grep -qi "Render process.*crash wasn't handled" artifacts/logcat-final.txt 2>/dev/null; then
  echo "renderer-death FATAL found (BAD)"; echo "renderer_fatal=YES" >> artifacts/RESULT.md
else
  echo "no renderer-death FATAL (GOOD)"; echo "renderer_fatal=NO" >> artifacts/RESULT.md
fi
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
{
  echo "RESULT: install_ok=$INSTALL_OK p1_chooser=$CHOOSER p1=$P1_OUTCOME p2_chooser=$CHOOSER2 p2=$P2_OUTCOME"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee -a artifacts/RESULT.md
docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
