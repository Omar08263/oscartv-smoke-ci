#!/usr/bin/env bash
# Kolnovel v8.2 VERIFY job 2 (D2) — renderer-death retry dialog, v8 proof.
# v8 carries the v7.1 fatal-fallback fix unchanged (adapterWriteStarted +
# fallbackSuppressed + generation guard) plus the 240 s write latch. v7
# retry3 PROVED the dialog could never appear (app died 1.2 s after the
# kill with "printing is already pending"); v7.1 fixed the mechanism
# statically only. This job proves it LIVE on v8:
# trigger: poll every 5s for the auto-save PDF file to APPEAR in
#   Download/Kolnovel/ — the file is created when printing STARTS (76237
#   timing: file opens ~+45s, write finishes ~+69s). Kill ALL
#   sandboxed_process the moment the file appears: the print WebView
#   definitely exists and onWrite is in flight. If the PDF completes before
#   any kill opportunity, that is NOT-PROVEN (too fast) with the evidence.
# After the kill: app must stay alive + Arabic dialog visible
# («تعطّل عارض العرض أثناء التصدير» + «إعادة المحاولة», checked at +15s AND
# +45s) -> tap retry -> export completes, PDF pulled + verified (1-250).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v8.6-common.sh
source scripts/kolnovel-redroid-v8.6-common.sh

# tap_button_text $1=exact button text — taps ONLY a clickable
# android.widget.Button with exactly this text.
# HARNESS FIX (run 44478047693, proven): common.sh tap_text() taps the FIRST
# node containing the text, which for the retry dialog is the NON-CLICKABLE
# message TextView ("...يمكنك إعادة المحاولة الآن.", bounds [59,520][673,688])
# — 31 taps landed on the message, the dialog never dismissed, no retry ever
# started, logcat showed zero app activity after the kill. The real button is
# android.widget.Button clickable=true bounds [35,720][362,816]. This helper
# refuses any non-Button / non-clickable node, so a tap that "sends" really
# presses the button.
tap_button_text() {
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
    t = (node.get('text') or '').strip()
    if t == needle and node.get('class') == 'android.widget.Button' and node.get('clickable') == 'true':
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print((x1+x2)//2, (y1+y2)//2); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  echo "tap_button_text: tapping Button '$needle' at $bounds"
  adb -s "$DEV" shell input tap $bounds 2>&1
  return 0
}

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V8_APK" "$V8_SHA" "${VARIANT:-v8.6}"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
sleep 3
adb connect "$DEV" >/dev/null 2>&1 || true

echo "== start export 76237 via deep link (v8.2: 2 parts, tap Part 1) =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/deeplink.log || true
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
if grep -q "PdfExportActivity" artifacts/logcat-afterstart.txt 2>/dev/null; then
  echo "PdfExportActivity started" | tee -a "$RESULT"
else
  echo "WARNING: PdfExportActivity NOT in afterstart logcat" | tee -a "$RESULT"
fi
# v8.2: 76237 (451 ch) now has 2 parts — wait for the chooser, tap Part 1.
CHOOSER=0
for c in $(seq 1 15); do
  dump_ui "retry-chooser-$c" >/dev/null 2>&1
  if grep -qi "اختر الجزء" "artifacts/ui-retry-chooser-$c.xml" 2>/dev/null; then
    CHOOSER=1
    echo "PART CHOOSER appeared (poll $c)" | tee -a "$RESULT"
    grep -oE 'الجزء [0-9]+' "artifacts/ui-retry-chooser-$c.xml" 2>/dev/null | sort -u | tee -a "$RESULT"
    cp "artifacts/ui-retry-chooser-$c.xml" "artifacts/ui-retry-chooser.xml"
    break
  fi
  sleep 20
done
if [ "$CHOOSER" != "1" ]; then
  echo "retry_verdict=NOT-PROVEN (no part chooser appeared for 76237)" >> "$RESULT"
  snap "retry-nochooser"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE retry72=NOT-PROVEN-no-chooser"
  cat "$RESULT"
  exit 0
fi
if ! tap_regex "^الجزء 1 " "artifacts/ui-retry-chooser.xml"; then
  echo "retry_verdict=NOT-PROVEN (Part 1 tap failed)" >> "$RESULT"
  snap "retry-parttap-failed"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE retry72=NOT-PROVEN-part-tap-failed"
  cat "$RESULT"
  exit 0
fi
sleep 5
START_EPOCH=$(date +%s)
echo "Part 1 tapped; print-start clock reset (START_EPOCH=$START_EPOCH)" | tee -a "$RESULT"
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
      echo "DONE retry72=NOT-PROVEN-too-fast"
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
  echo "DONE retry72=NOT-PROVEN-no-pdf"
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
  echo "DONE retry72=NOT-PROVEN-no-renderer"
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

RETRY_VERDICT="FAIL"
if [ "$ALIVE" = "YES" ] && [ "$DIALOG_TITLE" = "1" ] && [ "$DIALOG_BTN" = "1" ]; then
  echo "== deleting killed (partial) PDF so the retry wait sees only a fresh file =="
  adb -s "$DEV" shell "rm -f '$PDFP'" 2>&1 || true
  : > artifacts/seen-pdfs.txt
  echo "== tapping 'إعادة المحاولة' =="
  # Re-dump fresh UI before tapping (the 45s dump is current).
  if tap_button_text "إعادة المحاولة"; then
    echo "retry tap sent" | tee -a "$RESULT"
    sleep 5
    snap "retry-aftertap"; dump_ui "retry-aftertap"
    OUTCOME="timeout"; PDFP2=""
    for w in $(seq 1 30); do
      sleep 30
      PDFP2=$(new_pdf)
      # NOTE: the killed print's PDF has the same path; new_pdf ignores seen
      # paths, but this path was never added to seen-pdfs.txt in this job,
      # so it is "new" here. A retried export rewrites the same file.
      if [ -n "$PDFP2" ]; then OUTCOME="autosave"; break; fi
      dump_ui "retry-wait-$w" >/dev/null 2>&1
      if grep -qi "إعادة المحاولة" "artifacts/ui-retry-wait-$w.xml" 2>/dev/null; then
        echo "  retry dialog appeared AGAIN at wait $w — tapping once more"
        tap_button_text "إعادة المحاولة" || true
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
    echo "retry_export_outcome=$OUTCOME pdf=$PDFP2" | tee -a "$RESULT"
    if [ "$OUTCOME" = "autosave" ]; then
      echo "$PDFP2" >> artifacts/seen-pdfs.txt
      wait_stable_pull "$PDFP2" "artifacts/retry-export.pdf"
      if [ "$PULL_OK" = "1" ]; then
        verify_pdf_v8 "artifacts/retry-export.pdf" 1 250 "retry"
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
echo "DONE retry72=$RETRY_VERDICT"
cat "$RESULT"
