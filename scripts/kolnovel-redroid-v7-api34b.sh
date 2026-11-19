#!/usr/bin/env bash
# Kolnovel v7 DIAG — auto-save on Android 14 / API 34 (one export, novel 76237).
# v7-diag2 FIX (run 44452585690 api34 bug): v1 pulled the PDF the instant `ls`
# first saw it — 0 bytes, empty artifact — and still claimed AUTOSAVE-WORKS.
# v2 waits for a STABLE NON-ZERO size and verifies the %PDF header + pdfinfo
# before claiming completion; otherwise the verdict is WRITE-STARTED-ONLY.
# v6 auto-save (direct `new` of android.print subclasses) was proven ONLY on
# API 33 (Android 13). This job boots Redroid 14 and runs ONE real export,
# then reports BY EVIDENCE which path actually happened:
#   (1) auto-save wrote the PDF to Download/Kolnovel/  => direct `new` works on 34
#   (2) the system print dialog appeared instead    => the dialog fallback works on 34
# If no Redroid 14 image can be pulled/booted, or the booted SDK is not 34,
# the job FAILS with the evidence — API 34 is then reported NOT PROVEN,
# never claimed from an API 33 run.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
EXPECTED_SHA="7144af9e19cbc5fa43a06302ff4cfca4ff71f4aa47346a621d0468df2d1525be"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
RESULT="artifacts/RESULT.md"
: > "$RESULT"

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
}
snap() {
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$1.png" 2>/dev/null || true
}
tap_text() {
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
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if needle in t or needle in cd:
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print((x1+x2)//2, (y1+y2)//2); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  adb -s "$DEV" shell input tap $bounds 2>&1
  return 0
}
alive() { adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; }
dismiss_onboarding() {
  tap_text "Consent" || tap_text "consent" || true
  sleep 3
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || true
  sleep 5
}

echo "== host =="
uname -m; nproc; free -h | head -2
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"

# Try Redroid 14 image tags in order; the first that pulls AND boots wins.
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

MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  "$IMAGE" androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then
  echo "API34_BOOT_FAILED (image $IMAGE)" | tee -a "$RESULT"
  echo "api34_verdict=NOT-PROVEN (Redroid 14 image did not boot)" >> "$RESULT"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  docker rm -f redroid >/dev/null 2>&1 || true
  exit 1
fi
SDK=$(adb -s "$DEV" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
REL=$(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
{
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r') Android $REL SDK $SDK abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
  echo "redroid_image=$IMAGE"
} | tee -a "$RESULT"
if [ "$SDK" != "34" ]; then
  echo "API34_WRONG_SDK: booted SDK is $SDK, not 34 — NOT an API 34 test" | tee -a "$RESULT"
  echo "api34_verdict=NOT-PROVEN (booted SDK=$SDK)" >> "$RESULT"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  docker rm -f redroid >/dev/null 2>&1 || true
  exit 1
fi
echo "API LEVEL CONFIRMED: SDK 34 (Android 14)" | tee -a "$RESULT"

echo "== verify APK sha + install + launch =="
ACTUAL_SHA=$(sha256sum "$APK" | cut -d' ' -f1)
echo "apk sha256: $ACTUAL_SHA (expected $EXPECTED_SHA)" | tee -a "$RESULT"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] && echo "apk_sha=MATCH" >> "$RESULT" || echo "apk_sha=MISMATCH" >> "$RESULT"
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
INSTALL_OK=0
grep -q "Success" artifacts/install.log && INSTALL_OK=1
echo "install_ok=$INSTALL_OK" | tee -a "$RESULT"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15
snap launch; dump_ui launch
dismiss_onboarding
snap home; dump_ui home

echo "== export 76237 (401 ch) on API 34 via kexport:// deep link =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://76237" 2>&1 | tee artifacts/deeplink.log || true
sleep 10
adb -s "$DEV" logcat -d > artifacts/logcat-afterstart.txt 2>&1 || true
OUTCOME="timeout"
PDFP=""
for w in $(seq 1 20); do
  sleep 30
  PDFP=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
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
# Auto-save evidence lines from logcat (tryAutoSave / callbacks / MediaStore write / dialog fallback).
{
  echo "--- auto-save evidence (logcat-final.txt) ---"
  grep -i -E "tryAutoSave|KolnovelLayoutCallback|KolnovelWriteCallback|onLayoutFinished|onWriteFinished|MediaStore|Download/Kolnovel|printViaDialog|PrintManager|Select a printer" artifacts/logcat-final.txt | head -40 || echo "(no matching lines)"
  echo "--- fatal scan ---"
  echo -n "FATAL EXCEPTION: "; grep -c "FATAL EXCEPTION" artifacts/logcat-final.txt || true
  echo -n "Fatal signal: "; grep -c "Fatal signal" artifacts/logcat-final.txt || true
} | tee -a artifacts/api34-autosave-evidence.txt
if [ "$OUTCOME" = "autosave" ]; then
  # v7-diag2 FIX (run 44452585690 api34 bug): v1 pulled the PDF the instant
  # `ls` first saw it — the file was 0 bytes (write just started) and the
  # pulled artifact was empty, so "AUTOSAVE-WORKS" was overstated. v2 waits
  # for a STABLE NON-ZERO size before pulling, then verifies the header.
  echo "PDF seen on device; waiting for stable non-zero size..."
  LAST=-1; STABLE=0; SZ=0
  for w in $(seq 1 60); do
    SZ=$(adb -s "$DEV" shell "stat -c %s '$PDFP' 2>/dev/null" | tr -d '\r\n')
    echo "  size poll $w: ${SZ:-?}"
    if [ -n "$SZ" ] && [ "$SZ" -gt 0 ] 2>/dev/null && [ "$SZ" = "$LAST" ]; then STABLE=1; break; fi
    LAST="$SZ"
    sleep 10
  done
  echo "pdf size on device: $SZ bytes (stable=$STABLE)"
  adb -s "$DEV" pull "$PDFP" artifacts/exported-api34.pdf 2>&1 | tail -1
  ls -la artifacts/exported-api34.pdf 2>/dev/null || true
  if [ "$STABLE" = "1" ] && [ -s artifacts/exported-api34.pdf ] && head -c 5 artifacts/exported-api34.pdf | grep -q "%PDF-"; then
    echo "pulled PDF header OK (%PDF-)"
    sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -1 || true
    pdfinfo artifacts/exported-api34.pdf 2>&1 | grep -E "Pages:|File size:" | tee -a "$RESULT" || true
    echo "api34_verdict=AUTOSAVE-COMPLETE (direct new works on API 34; non-zero PDF written to Download/Kolnovel/ and pulled with valid %PDF header)" | tee -a "$RESULT"
  else
    echo "api34_verdict=WRITE-STARTED-ONLY (MediaStore file created on API 34 but no stable non-zero PDF was pulled; completion NOT verified)" | tee -a "$RESULT"
  fi
  snap "api34-autosave"
elif [ "$OUTCOME" = "print-dialog" ]; then
  snap "api34-printdialog"
  echo "api34_verdict=FALLBACK-DIALOG (auto-save did NOT write a PDF on API 34; system print dialog appeared instead — fallback works)" | tee -a "$RESULT"
else
  snap "api34-end"
  echo "api34_verdict=INCONCLUSIVE (outcome=$OUTCOME)" | tee -a "$RESULT"
fi
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE"
cat "$RESULT"
