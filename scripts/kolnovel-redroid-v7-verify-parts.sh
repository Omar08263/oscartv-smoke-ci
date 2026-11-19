#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 2 — parts: Part 3 alone (38916, ch 1001-1500) then
# Part 2 re-verification (ch 501-1000) on v7, via deep link kexport://38916.
# Each part: chooser -> tap "الجزء N" -> wait for auto-save PDF (up to 15 min)
# -> stable-size pull -> verify (headings full/sequential, Cairo body, FFFD=0).
# If a part fails, capture the FULL logcat + screenshot and retry ONCE;
# each attempt gets an independent verdict (content vs flake).
# During the wait, if the v7 retry dialog appears ("إعادة المحاولة"), tap it
# and keep waiting — recorded as retry_tapped=1 (the dialog itself is proven
# separately in the retry job; here it is only incidentally observed).
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

# export_part $1=N $2=LO $3=HI $4=attempt-tag (e.g. p3a1). Sets PART_VERDICT.
export_part() {
  local n="$1" lo="$2" hi="$3" atag="$4"
  local tag="p${n}${atag}"
  PART_VERDICT="UNVERIFIED"
  echo "########## PART $n (chapters $lo-$hi) attempt $atag ##########"
  cold_relaunch
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://38916" 2>&1 | tee "artifacts/$tag-deeplink.log" || true
  sleep 10
  adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-afterstart.txt" 2>&1 || true
  local chooser=0
  for c in $(seq 1 15); do
    dump_ui "$tag-chooser-$c" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-$tag-chooser-$c.xml" 2>/dev/null; then
      chooser=1
      echo "PART CHOOSER appeared (poll $c)"
      snap "$tag-chooser"
      cp "artifacts/ui-$tag-chooser-$c.xml" "artifacts/ui-$tag-chooser.xml"
      break
    fi
    sleep 20
  done
  if [ "$chooser" != "1" ]; then
    echo "$tag=NO-CHOOSER" | tee -a "$RESULT"
    adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-nochooser.txt" 2>&1 || true
    snap "$tag-nochooser"
    PART_VERDICT="NO-CHOOSER"
    return 0
  fi
  if ! tap_text "الجزء $n"; then
    echo "$tag=PART-TAP-FAILED" | tee -a "$RESULT"
    snap "$tag-parttap-failed"
    PART_VERDICT="PART-TAP-FAILED"
    return 0
  fi
  sleep 5
  snap "$tag-after-parttap"
  local outcome="timeout" pdfp="" retry_tapped=0
  for w in $(seq 1 30); do
    sleep 30
    pdfp=$(new_pdf)
    if [ -n "$pdfp" ]; then outcome="autosave"; break; fi
    dump_ui "$tag-wait-$w" >/dev/null 2>&1
    if grep -qi "إعادة المحاولة" "artifacts/ui-$tag-wait-$w.xml" 2>/dev/null; then
      echo "  [part $n] retry dialog seen at wait $w — tapping 'إعادة المحاولة'"
      retry_tapped=1
      tap_text "إعادة المحاولة" || true
      sleep 5
      continue
    fi
    if grep -qiE "Select a printer" "artifacts/ui-$tag-wait-$w.xml" 2>/dev/null; then outcome="print-dialog"; break; fi
    if ! alive; then
      outcome="died"
      adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-died.txt" 2>&1 || true
      grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-$tag-died.txt" > "artifacts/crash-$tag.txt" 2>/dev/null || true
      break
    fi
    if [ $((w % 10)) = 0 ]; then echo "  [part $n] waited $((w / 2)) min, no PDF/dialog yet"; fi
  done
  echo "$tag outcome=$outcome pdf=$pdfp retry_tapped=$retry_tapped" | tee -a "$RESULT"
  adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-end.txt" 2>&1 || true
  snap "$tag-end"
  if [ "$outcome" = "autosave" ]; then
    echo "$pdfp" >> artifacts/seen-pdfs.txt
    wait_stable_pull "$pdfp" "artifacts/part-$tag.pdf"
    if [ "$PULL_OK" = "1" ]; then
      verify_pdf "artifacts/part-$tag.pdf" "$lo" "$hi" "$tag"
      PART_VERDICT="$VERDICT"
      echo "$tag=$VERDICT (retry_tapped=$retry_tapped)" | tee -a "$RESULT"
    else
      echo "$tag=PULL-FAILED (stable=$STABLE, remote=$pdfp)" | tee -a "$RESULT"
      PART_VERDICT="PULL-FAILED"
    fi
  elif [ "$outcome" = "print-dialog" ]; then
    echo "$tag=PRINT-DIALOG-FALLBACK" | tee -a "$RESULT"
    PART_VERDICT="PRINT-DIALOG-FALLBACK"
  else
    echo "$tag=$outcome (full logcat: logcat-$tag-end.txt)" | tee -a "$RESULT"
    echo "--- renderer-death markers in $tag end logcat ---" | tee -a "$RESULT"
    grep -i -m 10 "sandboxed_process\|Renderer process.*crash\|onServiceDisconnected\|crash wasn't handled\|onRenderProcessGone" "artifacts/logcat-$tag-end.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
    PART_VERDICT="$outcome"
  fi
}

# Part 3: attempt 1, then exactly one retry if it fails.
export_part 3 1001 1500 "a1"
P3A1="$PART_VERDICT"
echo "P3 attempt1=$P3A1" | tee -a "$RESULT"
if ! echo "$P3A1" | grep -q "PASS"; then
  echo "P3 attempt 1 did NOT pass ($P3A1) — one retry to separate content vs flake"
  export_part 3 1001 1500 "a2"
  P3A2="$PART_VERDICT"
  echo "P3 attempt2=$P3A2" | tee -a "$RESULT"
else
  P3A2="not-run"
fi
# Part 2 re-verification on v7 (new button path never tested with a full export).
export_part 2 501 1000 "a1"
P2A1="$PART_VERDICT"
echo "P2 attempt1=$P2A1" | tee -a "$RESULT"
if ! echo "$P2A1" | grep -q "PASS"; then
  export_part 2 501 1000 "a2"
  P2A2="$PART_VERDICT"
  echo "P2 attempt2=$P2A2" | tee -a "$RESULT"
else
  P2A2="not-run"
fi

{
  echo "==================== PARTS SUMMARY ===================="
  echo "P3 attempt1=$P3A1 attempt2=$P3A2 (expected 500/500 ch 1001-1500)"
  echo "P2 attempt1=$P2A1 attempt2=$P2A2 (expected 500/500 ch 501-1000)"
} | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE PARTS p3a1=$P3A1 p3a2=$P3A2 p2a1=$P2A1 p2a2=$P2A2"
cat "$RESULT"
