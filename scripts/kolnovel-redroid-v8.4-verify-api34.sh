#!/usr/bin/env bash
# Kolnovel v8.2 VERIFY job 3 (D1) — API 34 auto-save (one export of 76237 on v8).
# Boots redroid:14.0.0-latest, REQUIRES SDK 34 (else NOT-PROVEN, never claimed
# from an API 33 run). Deep link kexport://76237 -> auto-save PDF in
# Download/Kolnovel/ -> stable-size pull -> verify (401/401, Cairo, FFFD=0).
# Confirms the v8 Java change (240 s latch) did not break auto-save on 34.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v8.4-common.sh
source scripts/kolnovel-redroid-v8.4-common.sh

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
IMAGE=""
for CAND in "redroid/redroid:14.0.0-latest" "redroid/redroid:14.0.0"; do
  echo "== trying image $CAND =="
  if docker pull "$CAND" 2>&1 | tail -3; then
    if docker image inspect "$CAND" >/dev/null 2>&1; then IMAGE="$CAND"; echo "image available: $IMAGE"; break; fi
  fi
  echo "image $CAND NOT available"
done
if [ -z "$IMAGE" ]; then
  echo "API34_IMAGE_UNAVAILABLE: no Redroid 14 image could be pulled" | tee -a "$RESULT"
  echo "api34_verdict=NOT-PROVEN (no API 34 Redroid image available)" >> "$RESULT"
  exit 1
fi
echo "redroid_image=$IMAGE" | tee -a "$RESULT"
boot_redroid "$IMAGE"
if [ "$BOOT_OK" != "1" ]; then
  echo "API34_BOOT_FAILED (image $IMAGE)" | tee -a "$RESULT"
  echo "api34_verdict=NOT-PROVEN (Redroid 14 image did not boot)" >> "$RESULT"
  stop_redroid
  exit 1
fi
SDK=$(adb -s "$DEV" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
if [ "$SDK" != "34" ]; then
  echo "API34_WRONG_SDK: booted SDK is $SDK, not 34 — NOT an API 34 test" | tee -a "$RESULT"
  echo "api34_verdict=NOT-PROVEN (booted SDK=$SDK)" >> "$RESULT"
  stop_redroid
  exit 1
fi
echo "API LEVEL CONFIRMED: SDK 34 (Android 14)" | tee -a "$RESULT"
install_apk "$V8_APK" "$V8_SHA" "v8.4"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

echo "== export 76237 part 1 (1-250 of 451 ch) on API 34 via kexport:// deep link =="
delete_old_pdfs
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/deeplink.log || true
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
# v8.2: 76237 (451 ch) now has 2 parts — wait for the chooser, tap Part 1.
CHOOSER=0
for c in $(seq 1 15); do
  dump_ui "api34-chooser-$c" >/dev/null 2>&1
  if grep -qi "اختر الجزء" "artifacts/ui-api34-chooser-$c.xml" 2>/dev/null; then
    CHOOSER=1
    echo "PART CHOOSER appeared (poll $c)" | tee -a "$RESULT"
    PARTS_SEEN=$(grep -oE 'الجزء [0-9]+' "artifacts/ui-api34-chooser-$c.xml" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    echo "api34_chooser_parts_seen=$PARTS_SEEN (expected 2)" | tee -a "$RESULT"
    grep -oE 'الجزء [0-9]+[^<]{0,60}' "artifacts/ui-api34-chooser-$c.xml" 2>/dev/null | sort -u | tee -a "$RESULT"
    cp "artifacts/ui-api34-chooser-$c.xml" "artifacts/ui-api34-chooser.xml"
    break
  fi
  sleep 20
done
if [ "$CHOOSER" != "1" ]; then
  echo "api34_verdict=NOT-PROVEN (no part chooser appeared for 76237)" | tee -a "$RESULT"
  snap "api34-nochooser"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  crash_scan
  stop_redroid
  echo "DONE api34 outcome=no-chooser"
  cat "$RESULT"
  exit 0
fi
tap_regex "^الجزء 1 " "artifacts/ui-api34-chooser.xml" || tap_text "الجزء 1" || true
sleep 5
OUTCOME="timeout"; PDFP=""
for w in $(seq 1 20); do
  sleep 30
  PDFP=$(new_pdf)
  if [ -n "$PDFP" ]; then OUTCOME="autosave"; break; fi
  dump_ui "wait-$w" >/dev/null 2>&1
  if grep -qiE "Select a printer" "artifacts/ui-wait-$w.xml" 2>/dev/null; then OUTCOME="print-dialog"; break; fi
  if ! alive; then
    OUTCOME="died"
    adb -s "$DEV" logcat -d > artifacts/logcat-died.txt 2>&1 || true
    grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" artifacts/logcat-died.txt > artifacts/crash.txt 2>/dev/null || true
    break
  fi
  if [ $((w % 5)) = 0 ]; then echo "  waited $((w / 2)) min, no PDF/dialog yet"; fi
done
echo "api34_export_outcome=$OUTCOME pdf=$PDFP" | tee -a "$RESULT"
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
{
  echo "--- auto-save evidence (logcat-final.txt) ---"
  grep -i -E "tryAutoSave|KolnovelLayoutCallback|KolnovelWriteCallback|onLayoutFinished|onWriteFinished|MediaStore|Download/Kolnovel|printViaDialog|PrintManager|Select a printer" artifacts/logcat-final.txt | head -40 || echo "(no matching lines)"
  echo "--- fatal scan ---"
  echo -n "FATAL EXCEPTION: "; grep -c "FATAL EXCEPTION" artifacts/logcat-final.txt || true
  echo -n "Fatal signal: "; grep -c "Fatal signal" artifacts/logcat-final.txt || true
} | tee -a artifacts/api34-autosave-evidence.txt
if [ "$OUTCOME" = "autosave" ]; then
  echo "$PDFP" >> artifacts/seen-pdfs.txt
  wait_stable_pull "$PDFP" "artifacts/exported-api34.pdf"
  if [ "$PULL_OK" = "1" ]; then
    verify_pdf_v8 "artifacts/exported-api34.pdf" 1 250 "api34"
    if echo "$VERDICT" | grep -q "PASS"; then
      echo "api34_verdict=AUTOSAVE-COMPLETE (direct new works on API 34; $VERDICT)" | tee -a "$RESULT"
    else
      echo "api34_verdict=FAIL (PDF pulled on API 34 but verification failed: $VERDICT)" | tee -a "$RESULT"
    fi
    snap "api34-autosave"
  else
    echo "api34_verdict=WRITE-STARTED-ONLY (MediaStore file created on API 34 but no stable non-zero PDF was pulled; completion NOT verified)" | tee -a "$RESULT"
  fi
elif [ "$OUTCOME" = "print-dialog" ]; then
  snap "api34-printdialog"
  echo "api34_verdict=FALLBACK-DIALOG (auto-save did NOT write a PDF on API 34; system print dialog appeared instead — fallback works)" | tee -a "$RESULT"
else
  snap "api34-end"
  echo "api34_verdict=INCONCLUSIVE (outcome=$OUTCOME)" | tee -a "$RESULT"
fi
crash_scan
stop_redroid
echo "DONE api34 outcome=$OUTCOME"
cat "$RESULT"
