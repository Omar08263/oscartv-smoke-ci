#!/usr/bin/env bash
# Kolnovel v8.5 VERIFY job 5 (isolation variant) — cold-open regression (12 cold detail-opens of
# 38916 via Latin search «Reverend», button visible at top with NO scrolling,
# ONE tap -> PdfExportActivity). Same checks as the v8 smoke gate (run
# 44477253543, PASS), re-run here as the regression item inside the verify
# matrix. Detail verified by title + the detail-only tab «المحتوى».
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v8.5-common.sh
source scripts/kolnovel-redroid-v8.5-common.sh

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V8_APK" "$V8_SHA" "${VARIANT:-v8.5}"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

echo "== cold detail-open x12 of 38916 via search (v8 regression A1+A2) =="
OPEN_PASS=0; BTN_PASS=0; TAP_PASS=0; TAP_TRIES=0
for i in $(seq 1 12); do
  echo "########## cold open $i/12 ##########"
  cold_relaunch
  adb -s "$DEV" logcat -c 2>&1 || true
  open_novel_by_search "القس المجنون" "n$i" "Reverend"
  echo "n${i}_open=$OPEN_OK" | tee -a "$RESULT"
  if [ "$OPEN_OK" != "1" ]; then
    echo "cold $i: DETAIL FAILED (OPEN_OK=$OPEN_OK)" | tee -a "$RESULT"
    adb -s "$DEV" logcat -d > "artifacts/logcat-n${i}-failed.txt" 2>&1 || true
    snap "n${i}-failed"
    continue
  fi
  OPEN_PASS=$((OPEN_PASS + 1))
  BTN=0
  grep -q "تصدير PDF" "artifacts/ui-n${i}-detail-top.xml" 2>/dev/null && BTN=1
  echo "n${i}_button_visible_top=$BTN" | tee -a "$RESULT"
  [ "$BTN" = "1" ] && BTN_PASS=$((BTN_PASS + 1))
  # Button-tap proof on the FIRST 3 successful opens only (A2: 3/3 taps
  # start PdfExportActivity). Later opens only need open+button-visible.
  if [ "$TAP_TRIES" -lt 3 ] && [ "$BTN" = "1" ]; then
    TAP_TRIES=$((TAP_TRIES + 1))
    echo "== tap $TAP_TRIES/3 on تصدير PDF (open $i) =="
    adb -s "$DEV" logcat -c 2>&1 || true
    if tap_text "تصدير PDF"; then
      sleep 10
      adb -s "$DEV" logcat -d > "artifacts/logcat-press-$i.txt" 2>&1 || true
      snap "press-$i-aftertap"; dump_ui "press-$i-aftertap"
      STARTED=0; CHOOSER=0; CRASHED=0
      grep -q "PdfExportActivity" "artifacts/logcat-press-$i.txt" 2>/dev/null && STARTED=1
      grep -qi "اختر الجزء" "artifacts/ui-press-$i-aftertap.xml" 2>/dev/null && CHOOSER=1
      alive || CRASHED=1
      echo "press${i}_started=$STARTED chooser=$CHOOSER crashed=$CRASHED" | tee -a "$RESULT"
      [ "$STARTED" = "1" ] && [ "$CRASHED" = "0" ] && TAP_PASS=$((TAP_PASS + 1))
    else
      echo "press${i}: button tap FAILED (no tappable node)" | tee -a "$RESULT"
    fi
  fi
done
echo "coldopen_summary: opens=$OPEN_PASS/12 button_visible_top=$BTN_PASS/12 taps_started_pdfexport=$TAP_PASS/3 (tries=$TAP_TRIES)" | tee -a "$RESULT"
# v8.4 (task A2): the crash-fix question is also "0 hasMore / 0 page.data in
# logcat" across all 12 cold opens — count them directly, never infer.
{
  echo "coldopen_crash_markers (all captured logcats):"
  echo -n "  FATAL EXCEPTION lines: "; grep -h -c "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "  TypeError lines: "; grep -h -c -i "TypeError" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "  hasMore lines: "; grep -h -c "hasMore" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "  page.data lines: "; grep -h -c "page.data" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "  Fatal signal lines (ALL signals, not just SIGSEGV): "; grep -h -c "Fatal signal" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "    of which SIGSEGV (signal 11): "; grep -h -c "Fatal signal 11" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo -n "    of which SIGABRT (signal 6): "; grep -h -c "Fatal signal 6" artifacts/logcat-*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}'
  echo "  Fatal-signal PCs (first #00 pc per failed logcat):"
  grep -h -A 12 "Fatal signal" artifacts/logcat-*.txt 2>/dev/null | grep -E "#00 pc" | sort | uniq -c | sort -rn || echo "  (none)"
  echo "  Fatal-signal fault addrs:"
  grep -h "fault addr" artifacts/logcat-*.txt 2>/dev/null | sort -u || echo "  (none)"
} | tee -a "$RESULT"
if [ "$OPEN_PASS" = "12" ] && [ "$BTN_PASS" = "12" ] && [ "$TAP_PASS" = "3" ]; then
  echo "coldopen_verdict=PASS (12/12 cold opens, button visible at top 12/12, 3/3 taps started PdfExportActivity)" | tee -a "$RESULT"
elif [ "$OPEN_PASS" = "12" ] && [ "$TAP_PASS" = "3" ]; then
  echo "coldopen_verdict=PARTIAL (opens 12/12, taps 3/3, but button_visible_top=$BTN_PASS/12)" | tee -a "$RESULT"
else
  echo "coldopen_verdict=FAIL (opens=$OPEN_PASS/12 button=$BTN_PASS/12 taps=$TAP_PASS/3)" | tee -a "$RESULT"
fi
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE coldopen opens=$OPEN_PASS/12 btn=$BTN_PASS/12 taps=$TAP_PASS/3"
cat "$RESULT"
