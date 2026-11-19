#!/usr/bin/env bash
# Kolnovel v7 VERIFY — v6 CONTROL for the retry3 result (same kill trigger).
# Question: retry3 (v7) died 1.2s after a mid-print renderer kill with
#   `IllegalStateException: printing is already pending` (WV.I6.onWrite) —
#   is that a v7 REGRESSION (the new retry code broke the guard) or
#   version-independent Chromium behavior (the framework re-issues onWrite
#   while one is pending, killing the app before onRenderProcessGone can act)?
# Method: run the IDENTICAL kill (PDF-appearance trigger, kill at print
#   start) against the v6 APK (which has the PROVEN B3 guard: onRenderProcessGone
#   -> true + toast, no dialog). v6 has no retry dialog, so the ONLY verdict
#   here is app_alive + the FATAL type (if any):
#     v6 SURVIVES  => the v7 death is v7-specific (retry change broke it)
#     v6 DIES with the SAME "printing is already pending" => Chromium behavior,
#       version-independent; the retry dialog cannot fire in a mid-write kill.
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
install_apk "app/Kolnovel-v5.2.5-premium-v6.apk" "7144af9e19cbc5fa43a06302ff4cfca4ff71f4aa47346a621d0468df2d1525be" "v6"
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
# Poll every 5s for the PDF file to appear (print start). Kill immediately.
echo "polling every 5s for the auto-save PDF to appear (print start)..."
PDFP=""; KILL_AT=""
for i in $(seq 1 24); do
  sleep 5
  ELAPSED=$(( $(date +%s) - START_EPOCH ))
  PDFP=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
  if [ -n "$PDFP" ]; then
    SZ=$(adb -s "$DEV" shell "stat -c %s '$PDFP' 2>/dev/null" | tr -d '\r\n')
    echo "  +${ELAPSED}s PDF appeared: $PDFP size=${SZ:-?}"
    if [ -n "$SZ" ] && [ "$SZ" -gt 1000000 ] 2>/dev/null; then
      echo "PDF already >1MB at first sight (+${ELAPSED}s) — print nearly done, kill window missed" | tee -a "$RESULT"
      echo "retry_verdict=NOT-PROVEN (PDF >1MB before any kill opportunity at +${ELAPSED}s)" >> "$RESULT"
      snap "too-fast"
      adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
      stop_redroid
      echo "DONE retry3=NOT-PROVEN-too-fast"
      cat "$RESULT"
      exit 0
    fi
    KILL_AT="+${ELAPSED}s"
    break
  fi
  if [ "$ELAPSED" -ge 120 ]; then break; fi
done
if [ -z "$PDFP" ]; then
  echo "NO PDF appeared within ~120s — export never reached print" | tee -a "$RESULT"
  echo "retry_verdict=NOT-PROVEN (no auto-save PDF within 120s)" >> "$RESULT"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  snap "no-pdf"
  stop_redroid
  echo "DONE retry3=NOT-PROVEN-no-pdf"
  cat "$RESULT"
  exit 0
fi
RENDERER_PIDS=$(adb -s "$DEV" shell "ps -A -o PID,NAME 2>/dev/null | grep -i 'sandboxed_process' | awk '{print \$1}'" 2>/dev/null | tr '\r\n' ' ' | tr -d ' ')
echo "renderer pids at kill ($KILL_AT): ${RENDERER_PIDS:-none}" | tee -a "$RESULT"
echo "renderer_pids=${RENDERER_PIDS:-none} kill_at=$KILL_AT pdf=$PDFP" >> "$RESULT"
if [ -z "$RENDERER_PIDS" ]; then
  echo "NO RENDERER at print start ($KILL_AT) — cannot kill the print renderer" | tee -a "$RESULT"
  echo "retry_verdict=NOT-PROVEN (no sandboxed_process at print start)" >> "$RESULT"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE retry3=NOT-PROVEN-no-renderer"
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
# Second dialog check at +45s after the kill (the dialog may take a moment).
sleep 30
snap "afterkill-45s"
dump_ui "afterkill-45s"
adb -s "$DEV" logcat -d > artifacts/logcat-afterkill-45s.txt 2>&1 || true

ALIVE="NO"; alive && ALIVE="YES"
echo "app_alive_after_kill=$ALIVE" | tee -a "$RESULT"
{
  echo "--- renderer-death markers (logcat-afterkill-45s.txt) ---"
  grep -i -m 15 "onServiceDisconnected\|Renderer process.*crash detected\|WebView render process crashed\|crash wasn't handled\|onRenderProcessGone\|sandboxed_process" artifacts/logcat-afterkill-45s.txt 2>/dev/null || echo "(none)"
  echo "--- app FATAL check ---"
  grep -i -m 5 "FATAL EXCEPTION" artifacts/logcat-afterkill-45s.txt 2>/dev/null || echo "(no FATAL EXCEPTION lines)"
  grep -i -m 5 "Fatal signal" artifacts/logcat-afterkill-45s.txt 2>/dev/null || echo "(no Fatal signal lines)"
} | tee -a "$RESULT"
DIALOG_TITLE=0; DIALOG_BTN=0
for f in artifacts/ui-afterkill.xml artifacts/ui-afterkill-45s.xml; do
  grep -q "تعطّل عارض العرض أثناء التصدير" "$f" 2>/dev/null && DIALOG_TITLE=1
  grep -q "إعادة المحاولة" "$f" 2>/dev/null && DIALOG_BTN=1
done
echo "dialog_title_visible=$DIALOG_TITLE dialog_retry_button_visible=$DIALOG_BTN" | tee -a "$RESULT"
if [ "$DIALOG_TITLE" = "1" ] && [ "$DIALOG_BTN" = "1" ]; then
  echo "RETRY DIALOG VISIBLE in UI dump (title + button)" | tee -a "$RESULT"
  grep -o "تعطّل عارض العرض أثناء التصدير[^<]*" artifacts/ui-afterkill-45s.xml 2>/dev/null | head -2 | tee -a "$RESULT"
fi

RETRY_VERDICT="UNVERIFIED"
FATAL_TYPE=$(grep -m 1 -A 2 "FATAL EXCEPTION" artifacts/logcat-afterkill-45s.txt 2>/dev/null | grep -oE "java\.lang\.[A-Za-z]+|Render process.*wasn't handled" | head -1 || echo none)
FATAL_STACK=$(grep -m 1 -A 3 "FATAL EXCEPTION" artifacts/logcat-afterkill-45s.txt 2>/dev/null | tail -2 | head -1 || echo none)
echo "v6_fatal_type=${FATAL_TYPE:-none}" | tee -a "$RESULT"
echo "v6_fatal_stack_line=${FATAL_STACK:-none}" | tee -a "$RESULT"
if [ "$ALIVE" = "YES" ]; then
  RETRY_VERDICT="V6-CONTROL: SURVIVED (app alive after mid-print renderer kill — v6 guard held; the v7 death would then be v7-specific)"
else
  RETRY_VERDICT="V6-CONTROL: DIED (app died after mid-print renderer kill; fatal_type=${FATAL_TYPE:-none} — if 'printing is already pending', the v7 death is version-independent Chromium behavior)"
fi
echo "v6control_verdict=$RETRY_VERDICT" | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE v6control=$RETRY_VERDICT"
cat "$RESULT"
