#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 5 — fold stress (one round, v7).
# Cold open of 38916 via search, then scroll the detail list up/down 3 times
# (fold/unfold the collapsible header) and tap "تصدير PDF" — 0 crashes.
# This exercises the re-render path the v6 crash lived in (ANALYSIS §2 H9).
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
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V7_APK" "$V7_SHA" "v7"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "fold-n1" "Reverend"
echo "fold_n1_open=$OPEN_OK (1=ok 2=crashed 0=miss)" | tee -a "$RESULT"
FOLD_VERDICT="FAIL"
if [ "$OPEN_OK" = "1" ]; then
  echo "== fold stress: 3x scroll up/down =="
  for i in 1 2 3; do
    adb -s "$DEV" shell input swipe 360 1200 360 400 300 2>&1 || true
    sleep 3
    adb -s "$DEV" shell input swipe 360 400 360 1200 300 2>&1 || true
    sleep 3
    if ! alive; then echo "fold: APP DIED during scroll round $i (CRASH)" | tee -a "$RESULT"; break; fi
    echo "fold: scroll round $i done, app alive"
  done
  snap "fold-after-scrolls"; dump_ui "fold-after-scrolls"
  if alive; then
    echo "fold_scrolls=3/3 app alive after all scrolls" | tee -a "$RESULT"
    # Scroll back to top so the button (above the fold) is visible, then tap.
    adb -s "$DEV" shell input swipe 360 400 360 1200 300 2>&1 || true
    sleep 3
    adb -s "$DEV" shell input swipe 360 400 360 1200 300 2>&1 || true
    sleep 3
    dump_ui "fold-before-tap"
    if grep -q "تصدير PDF" artifacts/ui-fold-before-tap.xml 2>/dev/null; then
      echo "fold: button visible after scrolls" | tee -a "$RESULT"
      adb -s "$DEV" logcat -c 2>&1 || true
      if tap_text "تصدير PDF"; then
        started=0; chooser=0; crashed=0
        for w in $(seq 1 9); do
          sleep 10
          adb -s "$DEV" logcat -d > artifacts/logcat-fold-press.txt 2>&1 || true
          if grep -q "PdfExportActivity" artifacts/logcat-fold-press.txt 2>/dev/null; then started=1; fi
          dump_ui "fold-press-w$w" >/dev/null 2>&1
          if grep -qi "اختر الجزء" "artifacts/ui-fold-press-w$w.xml" 2>/dev/null; then chooser=1; fi
          if ! alive; then crashed=1; break; fi
          if [ "$started" = "1" ]; then break; fi
        done
        snap "fold-press-aftertap"; dump_ui "fold-press-aftertap"
        echo "fold_press: started=$started chooser=$chooser crashed=$crashed" | tee -a "$RESULT"
        grep -i "PdfExportActivity" artifacts/logcat-fold-press.txt 2>/dev/null | head -5 | tee -a "$RESULT" || true
        if [ "$crashed" = "1" ]; then
          crash_excerpt artifacts/logcat-fold-press.txt artifacts/crash-fold-press.txt
          FOLD_VERDICT="FAIL (app crashed on button tap after fold stress)"
        elif [ "$started" = "1" ]; then
          FOLD_VERDICT="PASS (3 scroll rounds + button tap started PdfExportActivity, 0 crashes)"
        else
          FOLD_VERDICT="FAIL (button tap did not start PdfExportActivity in 90s)"
        fi
      else
        FOLD_VERDICT="FAIL (button visible but not tappable after scrolls)"
      fi
    else
      echo "fold: button NOT in dump after scrolls (screenshot: screen-fold-before-tap.png)" | tee -a "$RESULT"
      FOLD_VERDICT="FAIL (button absent after fold stress)"
    fi
  else
    adb -s "$DEV" logcat -d > artifacts/logcat-fold-crash.txt 2>&1 || true
    crash_excerpt artifacts/logcat-fold-crash.txt artifacts/crash-fold.txt
    FOLD_VERDICT="FAIL (app died during fold scrolls)"
  fi
elif [ "$OPEN_OK" = "2" ]; then
  FOLD_VERDICT="FAIL (detail open itself crashed — see crash-fold-n1-open.txt)"
else
  FOLD_VERDICT="INCONCLUSIVE (detail never opened, OPEN_OK=0)"
fi
echo "fold_verdict=$FOLD_VERDICT" | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE fold=$FOLD_VERDICT"
cat "$RESULT"
