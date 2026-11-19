#!/usr/bin/env bash
# Kolnovel v7.2 VERIFY job 4 — cold-open regression (one cold detail-open of
# 38916 via Latin search «Reverend», button visible at top with NO scrolling,
# ONE tap -> PdfExportActivity). Same checks as the v7.2 smoke gate (run
# 44477253543, PASS), re-run here as the regression item inside the verify
# matrix. Detail verified by title + the detail-only tab «المحتوى».
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
install_apk "$V7_APK" "$V7_SHA" "v7.2"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

echo "== cold detail-open of 38916 via search =="
cold_relaunch
adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "n1" "Reverend"
echo "n1_open=$OPEN_OK" | tee -a "$RESULT"
if [ "$OPEN_OK" != "1" ]; then
  echo "coldopen_verdict=FAIL (detail never opened, OPEN_OK=$OPEN_OK)" | tee -a "$RESULT"
  crash_scan
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE coldopen=FAIL"
  cat "$RESULT"
  exit 0
fi
BTN=0
grep -q "تصدير PDF" artifacts/ui-n1-detail-top.xml 2>/dev/null && BTN=1
echo "button_visible_top=$BTN" | tee -a "$RESULT"
snap "n1-detail-top"
echo "== one tap on تصدير PDF =="
adb -s "$DEV" logcat -c 2>&1 || true
if tap_text "تصدير PDF"; then
  echo "button tap sent" | tee -a "$RESULT"
else
  echo "button tap FAILED (no tappable node)" | tee -a "$RESULT"
  echo "coldopen_verdict=FAIL (button visible but not tappable)" | tee -a "$RESULT"
  crash_scan
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE coldopen=FAIL"
  cat "$RESULT"
  exit 0
fi
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-press.txt 2>&1 || true
snap "press-aftertap"
dump_ui "press-aftertap"
STARTED=0; CHOOSER=0; CRASHED=0
grep -q "PdfExportActivity" artifacts/logcat-press.txt 2>/dev/null && STARTED=1
grep -qi "اختر الجزء" artifacts/ui-press-aftertap.xml 2>/dev/null && CHOOSER=1
alive || CRASHED=1
echo "press_pdfexport_started=$STARTED press_part_chooser=$CHOOSER press_app_crashed=$CRASHED" | tee -a "$RESULT"
{
  echo "--- press logcat evidence ---"
  grep -m 5 "START u0.*kexport://38916" artifacts/logcat-press.txt 2>/dev/null || echo "(no START kexport line)"
  grep -m 5 "Displayed.*PdfExportActivity" artifacts/logcat-press.txt 2>/dev/null || echo "(no Displayed PdfExportActivity line)"
} | tee -a "$RESULT"
if [ "$STARTED" = "1" ] && [ "$CRASHED" = "0" ] && [ "$BTN" = "1" ]; then
  echo "coldopen_verdict=PASS (cold open OK, button visible at top, one tap started PdfExportActivity, chooser=$CHOOSER)" | tee -a "$RESULT"
else
  echo "coldopen_verdict=FAIL (started=$STARTED button=$BTN crashed=$CRASHED chooser=$CHOOSER)" | tee -a "$RESULT"
fi
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE coldopen"
cat "$RESULT"
