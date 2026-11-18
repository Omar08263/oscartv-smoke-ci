#!/usr/bin/env bash
# Kolnovel v4 - Button render check on Redroid (arm64, NO KVM).
# Verifies the "تصدير PDF" button actually RENDERS on a real novel detail
# screen and that tapping it starts PdfExportActivity.
# Steps: launch -> dismiss consent -> skip onboarding -> home -> tap a
# novel -> dump UI -> find "تصدير PDF" -> tap it -> confirm Activity.
# Best-effort navigation: every step is logged; the verdict is whether the
# button text appears in a UI dump on the detail screen.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v4.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
INSTALL_OK=0
BUTTON_FOUND=0
BUTTON_TAPPED=0

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
  echo "--- ui-$name (text nodes) ---"
  grep -o 'text="[^"]*"' artifacts/ui-$name.xml 2>/dev/null | head -40 || echo "(no ui dump)"
}

tap_text() {
  local needle="$1"
  local f="artifacts/ui-current.xml"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-current.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-current.xml "$f" 2>/dev/null
  # find bounds of the node whose text contains the needle
  local bounds
  bounds=$(python3 - "$f" "$needle" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
f, needle = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(f).getroot()
except Exception:
    sys.exit(1)
for node in root.iter('node'):
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if needle in t or needle in cd:
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print((x1+x2)//2, (y1+y2)//2)
            sys.exit(0)
sys.exit(1)
PYEOF
)
  if [ -n "$bounds" ]; then
    echo "tapping '$needle' at $bounds"
    # shellcheck disable=SC2086
    adb -s "$DEV" shell input tap $bounds 2>&1
    return 0
  fi
  echo "text '$needle' NOT found on screen"
  return 1
}

echo "== host =="
uname -m
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -3
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > artifacts/RESULT.md; exit 1; fi

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15
adb -s "$DEV" exec-out screencap -p > artifacts/screen-launch.png 2>/dev/null || true

if [ "$INSTALL_OK" = "1" ]; then
  echo "== dismiss consent dialog (if present) =="
  dump_ui launch
  tap_text "Consent" || tap_text "consent" || echo "no Consent button found (may already be dismissed)"
  sleep 5
  echo "== skip onboarding (tap Next / تخطي) =="
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || echo "no skip/next found"
  sleep 5
  dump_ui home
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-home.png 2>/dev/null || true

  echo "== open a novel (tap the first novel title/card) =="
  # Try a few likely novel entry points by tapping the centre-top area
  # where the home list usually shows the first novel.
  adb -s "$DEV" shell input tap 360 400 2>&1 || true
  sleep 8
  dump_ui afternovel
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-novel.png 2>/dev/null || true

  echo "== look for the PDF button =="
  if grep -q "تصدير PDF" artifacts/ui-afternovel.xml 2>/dev/null; then
    BUTTON_FOUND=1
    echo "BUTTON FOUND: 'تصدير PDF' present in the novel detail UI dump"
  else
    echo "BUTTON NOT in ui-afternovel; trying a second tap location"
    adb -s "$DEV" shell input tap 360 600 2>&1 || true
    sleep 8
    dump_ui afternovel2
    if grep -q "تصدير PDF" artifacts/ui-afternovel2.xml 2>/dev/null; then
      BUTTON_FOUND=1
      echo "BUTTON FOUND on second attempt"
    else
      echo "BUTTON NOT FOUND in either UI dump"
    fi
  fi

  if [ "$BUTTON_FOUND" = "1" ]; then
    echo "== tap the PDF button =="
    # re-dump to get fresh bounds, then tap
    if tap_text "تصدير PDF"; then
      BUTTON_TAPPED=1
      sleep 5
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-aftertap.png 2>/dev/null || true
      adb -s "$DEV" logcat -d > artifacts/logcat-aftertap.txt 2>&1 || true
      if grep -qi "PdfExportActivity" artifacts/logcat-aftertap.txt; then
        echo "BUTTON TAP: PdfExportActivity started (in logcat)"
      else
        echo "BUTTON TAP: PdfExportActivity NOT seen in logcat yet"
      fi
    fi
  fi
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
if grep -qi "FATAL EXCEPTION" artifacts/logcat-final.txt; then echo "FATAL found"; else echo "no FATAL"; fi
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true

{
  echo "RESULT: install_ok=$INSTALL_OK button_found=$BUTTON_FOUND button_tapped=$BUTTON_TAPPED"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
