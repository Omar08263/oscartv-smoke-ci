#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 3b — renderer-death retry dialog, ROUND 2.
# Round 1 (run 44466265799, retry job) was NOT-PROVEN: the 76237 export
# finished before the fixed +55s kill (PDF already saved at +65s; api34
# timing shows the print renderer spawns ~+40s and the write finishes
# ~+69s). This round polls every 5s from +25s and kills the FIRST
# sandboxed_process the moment it appears, so the kill lands inside the
# print window. If the PDF appears before any renderer, that is NOT-PROVEN
# (export too fast) with the evidence — never claimed from code.
# After the kill: app must stay alive + Arabic dialog visible
# («تعطّل عارض العرض أثناء التصدير» + «إعادة المحاولة») -> tap retry ->
# export completes, PDF pulled + verified (401/401, Cairo, FFFD=0).
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
START_EPOCH=$(date +%s)
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/deeplink.log || true
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
if grep -q "PdfExportActivity" artifacts/logcat-afterstart.txt 2>/dev/null; then
  echo "PdfExportActivity started" | tee -a "$RESULT"
else
  echo "WARNING: PdfExportActivity NOT in afterstart logcat" | tee -a "$RESULT"
fi
# Poll from +25s: kill the first sandboxed_process the moment it appears.
echo "polling every 5s from +25s for the print renderer..."
RENDERER_PIDS=""; KILL_AT=""
for i in $(seq 1 20); do
  sleep 5
  ELAPSED=$(( $(date +%s) - START_EPOCH ))
  EARLY_PDF=$(new_pdf)
  if [ -n "$EARLY_PDF" ]; then
    echo "EARLY-PDF already saved at +${ELAPSED}s: $EARLY_PDF — retry dialog NOT testable" | tee -a "$RESULT"
    echo "retry_verdict=NOT-PROVEN (export completed at +${ELAPSED}s before any renderer kill)" >> "$RESULT"
    snap "early-pdf"
    adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
    stop_redroid
    echo "DONE retry2=NOT-PROVEN-early-pdf"
    cat "$RESULT"
    exit 0
  fi
  RENDERER_PIDS=$(adb -s "$DEV" shell "ps -A -o PID,NAME 2>/dev/null | grep -i 'sandboxed_process' | awk '{print \$1}'" 2>/dev/null | tr '\r\n' ' ' | tr -d ' ')
  echo "  +${ELAPSED}s renderer pids: ${RENDERER_PIDS:-none}"
  if [ -n "$RENDERER_PIDS" ] && [ "$ELAPSED" -ge 25 ]; then
    KILL_AT="+${ELAPSED}s"
    break
  fi
done
if [ -z "$RENDERER_PIDS" ]; then
  echo "NO RENDERER FOUND within +120s — aborting" | tee -a "$RESULT"
  echo "retry_verdict=NOT-PROVEN (no sandboxed_process within +120s)" >> "$RESULT"
  adb -s "$DEV" logcat -d > artifacts/logcat-afterkill.txt 2>&1 || true
  snap "no-renderer"; dump_ui "no-renderer"
  stop_redroid
  echo "DONE retry2=NOT-PROVEN-no-renderer"
  cat "$RESULT"
  exit 0
fi
echo "renderer pids at kill ($KILL_AT): $RENDERER_PIDS" | tee -a "$RESULT"
echo "renderer_pids=$RENDERER_PIDS kill_at=$KILL_AT" >> "$RESULT"
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
echo "DONE retry2=$RETRY_VERDICT"
cat "$RESULT"
