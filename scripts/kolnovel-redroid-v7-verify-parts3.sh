#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 2b — Part 3 THIRD attempt (a3), follow-up evidence.
# Context (run 44466265799, parts job): P3 failed 2/2 on v7 with TWO different
# print-phase modes, and failed on v6 too (renderer death) — 3 consecutive
# P3 failures while P2/P4/P5 pass. a1: PDF created, 0 bytes for ~110s, then
# the file VANISHED (stat failed 49 polls; app-side partial-PDF cleanup is
# the only deleter). a2: PDF stuck at 0 bytes for 120s, app deleted the
# partial PDF at 05:53:41.980, then 0.3s later the app DIED with
# `java.lang.IllegalStateException: printing is already pending` at
# WV.I6.onWrite <- PrintManager (crash-p3a2.txt). No renderer death in
# either attempt, so the v7 retry dialog correctly never appeared.
# This attempt asks: does the P3 print-phase failure reproduce a third time,
# and in which mode? Harness fixes vs the round-1 parts job:
#  (a) the old Part 3 PDF is deleted from the device first (same filename
#      across attempts broke new_pdf detection in a2);
#  (b) a vanished file stops the size poll early as FILE-GONE instead of
#      polling blind for 10 min;
#  (c) logcat is snapshotted every 2 min during the wait (the ring buffer
#      rotated away the a1 deletion moment in round 1).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v7-common.sh
source scripts/kolnovel-redroid-v7-common.sh

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V7_APK" "$V7_SHA" "v7"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

TAG="p3a3"
echo "########## PART 3 (chapters 1001-1500) attempt a3 ##########"
# (a) remove any stale Part 3 PDF so new_pdf detection works for this attempt.
adb -s "$DEV" shell "rm -f '/sdcard/Download/Kolnovel/Kolnovel - القس المجنون - Part 3.pdf'" 2>&1 || true
adb -s "$DEV" shell "ls -la /sdcard/Download/Kolnovel/ 2>/dev/null" | tee -a "$RESULT" || true
cold_relaunch
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://38916" 2>&1 | tee "artifacts/$TAG-deeplink.log" || true
sleep 10
adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-afterstart.txt" 2>&1 || true
CHOOSER=0
for c in $(seq 1 15); do
  dump_ui "$TAG-chooser-$c" >/dev/null 2>&1
  if grep -qi "اختر الجزء" "artifacts/ui-$TAG-chooser-$c.xml" 2>/dev/null; then
    CHOOSER=1; echo "PART CHOOSER appeared (poll $c)"; snap "$TAG-chooser"
    cp "artifacts/ui-$TAG-chooser-$c.xml" "artifacts/ui-$TAG-chooser.xml"
    break
  fi
  sleep 20
done
if [ "$CHOOSER" != "1" ]; then
  echo "$TAG=NO-CHOOSER" | tee -a "$RESULT"
  adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-nochooser.txt" 2>&1 || true
  snap "$TAG-nochooser"
  stop_redroid; echo "DONE p3a3=NO-CHOOSER"; cat "$RESULT"; exit 0
fi
if ! tap_text "الجزء 3"; then
  echo "$TAG=PART-TAP-FAILED" | tee -a "$RESULT"
  stop_redroid; echo "DONE p3a3=PART-TAP-FAILED"; cat "$RESULT"; exit 0
fi
sleep 5
snap "$TAG-after-parttap"
OUTCOME="timeout"; PDFP=""; RETRY_TAPPED=0
for w in $(seq 1 30); do
  sleep 30
  PDFP=$(new_pdf)
  if [ -n "$PDFP" ]; then OUTCOME="autosave"; break; fi
  dump_ui "$TAG-wait-$w" >/dev/null 2>&1
  # (c) snapshot logcat every 2 min so the print-phase evidence survives.
  if [ $((w % 4)) = 0 ]; then
    adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-snap-$w.txt" 2>&1 || true
    echo "  [p3a3] logcat snapshot w$w saved"
  fi
  if grep -qi "إعادة المحاولة" "artifacts/ui-$TAG-wait-$w.xml" 2>/dev/null; then
    echo "  [p3a3] retry dialog seen at wait $w — tapping 'إعادة المحاولة'"
    RETRY_TAPPED=1
    tap_text "إعادة المحاولة" || true
    sleep 5
    continue
  fi
  if grep -qiE "Select a printer" "artifacts/ui-$TAG-wait-$w.xml" 2>/dev/null; then OUTCOME="print-dialog"; break; fi
  if ! alive; then
    OUTCOME="died"
    adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-died.txt" 2>&1 || true
    grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-$TAG-died.txt" > "artifacts/crash-$TAG.txt" 2>/dev/null || true
    break
  fi
  if [ $((w % 10)) = 0 ]; then echo "  [p3a3] waited $((w / 2)) min, no PDF/dialog yet"; fi
done
echo "$TAG outcome=$OUTCOME pdf=$PDFP retry_tapped=$RETRY_TAPPED" | tee -a "$RESULT"
adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-end.txt" 2>&1 || true
snap "$TAG-end"
P3A3="UNVERIFIED"
if [ "$OUTCOME" = "autosave" ]; then
  echo "$PDFP" >> artifacts/seen-pdfs.txt
  # (b) stable-size pull that stops early if the file vanishes (FILE-GONE).
  LAST=-1; STABLE=0; SZ=""; GONE=0
  for w in $(seq 1 60); do
    SZ=$(adb -s "$DEV" shell "stat -c %s '$PDFP' 2>/dev/null" | tr -d '\r\n')
    echo "  size poll $w: ${SZ:-?}"
    if [ -z "$SZ" ]; then
      GONE=$((GONE + 1))
      if [ "$GONE" -ge 3 ]; then echo "  file GONE (stat failed 3x in a row) — stopping"; break; fi
    else
      GONE=0
      if [ "$SZ" -gt 0 ] 2>/dev/null && [ "$SZ" = "$LAST" ]; then STABLE=1; break; fi
      LAST="$SZ"
    fi
    sleep 10
  done
  echo "remote size: ${SZ:-?} bytes (stable=$STABLE, gone_polls=$GONE)"
  adb -s "$DEV" logcat -d > "artifacts/logcat-$TAG-afterpull.txt" 2>&1 || true
  if [ "$STABLE" = "1" ]; then
    adb -s "$DEV" pull "$PDFP" "artifacts/part-$TAG.pdf" 2>&1 | tail -1
    if [ -s "artifacts/part-$TAG.pdf" ] && head -c 5 "artifacts/part-$TAG.pdf" | grep -q "%PDF-"; then
      verify_pdf "artifacts/part-$TAG.pdf" 1001 1500 "$TAG"
      P3A3="$VERDICT"
    else
      P3A3="PULL-FAILED"
    fi
  elif [ "$GONE" -ge 3 ]; then
    P3A3="FILE-GONE (PDF created at 0 bytes, then deleted mid-print — same mode as a1)"
    echo "--- deletion/cleanup markers in afterpull logcat ---" | tee -a "$RESULT"
    grep -i -m 10 "Deleted.*due to com.benabdellah\|Render process\|onServiceDisconnected\|crash wasn't handled\|onRenderProcessGone\|FATAL" "artifacts/logcat-$TAG-afterpull.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
  else
    P3A3="PULL-FAILED (stable=$STABLE)"
  fi
  echo "$TAG=$P3A3 (retry_tapped=$RETRY_TAPPED)" | tee -a "$RESULT"
elif [ "$OUTCOME" = "print-dialog" ]; then
  P3A3="PRINT-DIALOG-FALLBACK"
  echo "$TAG=$P3A3" | tee -a "$RESULT"
else
  P3A3="$OUTCOME"
  echo "$TAG=$OUTCOME (full logcat: logcat-$TAG-end.txt)" | tee -a "$RESULT"
  echo "--- renderer-death markers in $TAG end logcat ---" | tee -a "$RESULT"
  grep -i -m 10 "sandboxed_process\|Renderer process.*crash\|onServiceDisconnected\|crash wasn't handled\|onRenderProcessGone\|printing is already" "artifacts/logcat-$TAG-end.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
fi
echo "P3 attempt3=$P3A3" | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE p3a3=$P3A3"
cat "$RESULT"
