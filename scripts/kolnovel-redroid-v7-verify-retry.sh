#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 3 — renderer-death retry dialog (runtime proof).
# Start export of 76237 (401 ch) via deep link, wait ~55s (inside the print
# window: fetch ~43s, onLayout/onWrite ~43-70s), kill ALL sandboxed_process
# pids (B3 pattern from BUILD-V6.md Problem 2), then check:
#   (a) app process still alive (guard held, no Chromium SIGTRAP),
#   (b) the Arabic retry dialog is VISIBLE: «تعطّل عارض العرض أثناء التصدير»
#       + button «إعادة المحاولة» (screenshot + UI dump, read firsthand),
#   (c) tap «إعادة المحاولة» -> export completes, PDF pulled + verified
#       (401/401 headings, Cairo, FFFD=0).
# If no renderer exists at +55s, or the dialog never appears, that is a
# documented FAIL/NOT-PROVEN with the evidence — never claimed from code.
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

adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
sleep 3
adb connect "$DEV" >/dev/null 2>&1 || true

echo "== start export 76237 via deep link =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/deeplink.log || true
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
if grep -q "PdfExportActivity" artifacts/logcat-afterstart.txt 2>/dev/null; then
  echo "PdfExportActivity started" | tee -a "$RESULT"
else
  echo "WARNING: PdfExportActivity NOT in afterstart logcat" | tee -a "$RESULT"
fi
echo "waiting 55s to land inside the print phase (onLayout/onWrite)..."
sleep 55
RENDERER_PIDS=$(adb -s "$DEV" shell "ps -A -o PID,NAME 2>/dev/null | grep -i 'sandboxed_process' | awk '{print \$1}'" 2>/dev/null | tr '\r\n' ' ' | tr -d ' ')
echo "renderer pids before kill: ${RENDERER_PIDS:-none}" | tee -a "$RESULT"
echo "renderer_pids=${RENDERER_PIDS:-none}" >> "$RESULT"
# Did the export already finish before +55s? Then the kill window is gone.
EARLY_PDF=$(new_pdf)
if [ -n "$EARLY_PDF" ]; then
  echo "EARLY-PDF already saved before kill: $EARLY_PDF — retry dialog NOT testable in this run" | tee -a "$RESULT"
  echo "retry_verdict=NOT-PROVEN (export completed before the +55s kill window)" >> "$RESULT"
  snap "early-pdf"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE retry=NOT-PROVEN-early-pdf"
  cat "$RESULT"
  exit 0
fi
if [ -z "$RENDERER_PIDS" ]; then
  echo "NO RENDERER FOUND at +55s (no print WebView?) — aborting" | tee -a "$RESULT"
  echo "retry_verdict=NOT-PROVEN (no sandboxed_process at +55s)" >> "$RESULT"
  adb -s "$DEV" logcat -d > artifacts/logcat-afterkill.txt 2>&1 || true
  snap "no-renderer"
  dump_ui "no-renderer"
  stop_redroid
  echo "DONE retry=NOT-PROVEN-no-renderer"
  cat "$RESULT"
  exit 0
fi
for pid in $RENDERER_PIDS; do
  adb -s "$DEV" shell kill -9 "$pid" 2>&1 || echo "kill $pid FAILED"
  echo "killed renderer pid=$pid at $(date -u +%H:%M:%S)"
done
sleep 15
snap "afterkill"
dump_ui "afterkill"
adb -s "$DEV" logcat -d > artifacts/logcat-afterkill.txt 2>&1 || true

ALIVE="NO"; alive && ALIVE="YES"
echo "app_alive_after_kill=$ALIVE" | tee -a "$RESULT"
{
  echo "--- renderer-death markers (logcat-afterkill.txt) ---"
  grep -i -m 15 "onServiceDisconnected\|Renderer process.*crash detected\|WebView render process crashed\|crash wasn't handled\|onRenderProcessGone\|sandboxed_process" artifacts/logcat-afterkill.txt 2>/dev/null || echo "(none)"
  echo "--- app FATAL check ---"
  grep -i -m 5 "FATAL EXCEPTION" artifacts/logcat-afterkill.txt 2>/dev/null || echo "(no FATAL EXCEPTION lines)"
  grep -i -m 5 "Fatal signal" artifacts/logcat-afterkill.txt 2>/dev/null || echo "(no Fatal signal lines)"
} | tee -a "$RESULT"
DIALOG_TITLE=0; DIALOG_BTN=0
grep -q "تعطّل عارض العرض أثناء التصدير" artifacts/ui-afterkill.xml 2>/dev/null && DIALOG_TITLE=1
grep -q "إعادة المحاولة" artifacts/ui-afterkill.xml 2>/dev/null && DIALOG_BTN=1
echo "dialog_title_visible=$DIALOG_TITLE dialog_retry_button_visible=$DIALOG_BTN" | tee -a "$RESULT"
if [ "$DIALOG_TITLE" = "1" ] && [ "$DIALOG_BTN" = "1" ]; then
  echo "RETRY DIALOG VISIBLE in UI dump (title + button)" | tee -a "$RESULT"
  grep -o "تعطّل عارض العرض أثناء التصدير[^<]*" artifacts/ui-afterkill.xml | head -2 | tee -a "$RESULT"
fi

RETRY_VERDICT="FAIL"
if [ "$ALIVE" = "YES" ] && [ "$DIALOG_TITLE" = "1" ] && [ "$DIALOG_BTN" = "1" ]; then
  echo "== tapping 'إعادة المحاولة' =="
  if tap_text "إعادة المحاولة"; then
    echo "retry tap sent" | tee -a "$RESULT"
    sleep 5
    snap "retry-aftertap"; dump_ui "retry-aftertap"
    # Wait up to 15 min for the retried export to auto-save a PDF.
    OUTCOME="timeout"; PDFP=""
    for w in $(seq 1 30); do
      sleep 30
      PDFP=$(new_pdf)
      if [ -n "$PDFP" ]; then OUTCOME="autosave"; break; fi
      dump_ui "retry-wait-$w" >/dev/null 2>&1
      if grep -qi "إعادة المحاولة" "artifacts/ui-retry-wait-$w.xml" 2>/dev/null; then
        echo "  retry dialog appeared AGAIN at wait $w — tapping once more"
        tap_text "إعادة المحاولة" || true
        sleep 5
        continue
      fi
      if grep -qiE "Select a printer" "artifacts/ui-retry-wait-$w.xml" 2>/dev/null; then OUTCOME="print-dialog"; break; fi
      if ! alive; then
        OUTCOME="died"
        adb -s "$DEV" logcat -d > artifacts/logcat-retry-died.txt 2>&1 || true
        break
      fi
      if [ $((w % 10)) = 0 ]; then echo "  [retry] waited $((w / 2)) min, no PDF yet"; fi
    done
    echo "retry_export_outcome=$OUTCOME pdf=$PDFP" | tee -a "$RESULT"
    if [ "$OUTCOME" = "autosave" ]; then
      echo "$PDFP" >> artifacts/seen-pdfs.txt
      wait_stable_pull "$PDFP" "artifacts/retry-export.pdf"
      if [ "$PULL_OK" = "1" ]; then
        verify_pdf "artifacts/retry-export.pdf" 1 401 "retry"
        echo "retry_pdf=$VERDICT" | tee -a "$RESULT"
        if echo "$VERDICT" | grep -q "PASS"; then RETRY_VERDICT="PASS"; else RETRY_VERDICT="FAIL (retried PDF failed verification: $VERDICT)"; fi
      else
        RETRY_VERDICT="FAIL (retried export wrote a PDF but pull failed, stable=$STABLE)"
      fi
    elif [ "$OUTCOME" = "print-dialog" ]; then
      RETRY_VERDICT="FAIL (retry led to print dialog, not auto-save)"
    else
      RETRY_VERDICT="FAIL (retry tap sent but export outcome=$OUTCOME)"
    fi
  else
    echo "retry tap FAILED (no tappable node)" | tee -a "$RESULT"
    RETRY_VERDICT="FAIL (dialog visible but retry button not tappable)"
  fi
elif [ "$ALIVE" != "YES" ]; then
  RETRY_VERDICT="FAIL (app DIED after renderer kill — guard did not hold)"
else
  RETRY_VERDICT="FAIL (dialog NOT visible: title=$DIALOG_TITLE button=$DIALOG_BTN, app alive=$ALIVE)"
fi
echo "retry_verdict=$RETRY_VERDICT" | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE retry=$RETRY_VERDICT"
cat "$RESULT"
