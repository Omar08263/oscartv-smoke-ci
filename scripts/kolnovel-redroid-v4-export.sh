#!/usr/bin/env bash
# Kolnovel v4 - Full export test on Redroid (arm64, NO KVM).
# Taps "تصدير PDF", waits for the export to finish (fetch all chapters +
# build print HTML + WebView print), and confirms the SYSTEM PRINT DIALOG
# appears. Then attempts Save-as-PDF via the dialog and pulls the PDF.
# Steps: launch -> consent -> skip -> home -> tap novel -> find+tap button
# -> wait up to 300s for print dialog -> screenshot -> try Save as PDF.
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
    # If the target sits near the bottom edge (y>1000) the tap can miss or hit
    # the nav gesture area; swipe up to centre it, then re-find fresh bounds.
    local ty
    ty=$(echo "$bounds" | awk '{print $2}')
    if [ "$ty" -gt 1000 ]; then
      echo "target y=$ty near bottom edge; centring it first"
      adb -s "$DEV" shell input swipe 360 900 360 600 2>&1 || true
      sleep 3
      adb -s "$DEV" shell uiautomator dump /sdcard/ui-current.xml 2>/dev/null
      adb -s "$DEV" pull /sdcard/ui-current.xml "$f" 2>/dev/null
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
      if [ -z "$bounds" ]; then echo "target lost after centring swipe"; return 1; fi
      echo "re-found '$needle' at $bounds after centring"
    fi
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

  echo "== open a novel (tap the middle cover at 360,750) =="
  # Home layout (proven by run 44271864905 screen-home.png): novel covers
  # sit at y~700-800; the middle cover is at ~(360,750). Tapping there
  # opens the novel detail screen (NovelDetailsScreen -> SeriesListHeaderInner).
  adb -s "$DEV" shell input tap 360 750 2>&1 || true
  sleep 10
  dump_ui afternovel
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-novel.png 2>/dev/null || true

  echo "== look for the PDF button (scroll down to the chapter-list header) =="
  if grep -q "تصدير PDF" artifacts/ui-afternovel.xml 2>/dev/null; then
    BUTTON_FOUND=1
    echo "BUTTON FOUND: 'تصدير PDF' present in the novel detail UI dump"
  else
    echo "BUTTON NOT in ui-afternovel; scrolling down to the chapter-list header (up to 6 swipes)"
    for i in 1 2 3 4 5 6; do
      adb -s "$DEV" shell input swipe 360 900 360 300 2>&1 || true
      sleep 4
      dump_ui "afternovel-s$i"
      if grep -q "تصدير PDF" "artifacts/ui-afternovel-s$i.xml" 2>/dev/null; then
        BUTTON_FOUND=1
        echo "BUTTON FOUND after scroll #$i"
        cp "artifacts/ui-afternovel-s$i.xml" artifacts/ui-afternovel2.xml
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-novel2.png 2>/dev/null || true
        break
      fi
      echo "scroll #$i: button not yet visible"
    done
    if [ "$BUTTON_FOUND" != "1" ]; then
      echo "BUTTON NOT FOUND after 6 scrolls"
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-novel2.png 2>/dev/null || true
    fi
  fi

  PRINT_DIALOG=0
  PDF_SAVED=0
  if [ "$BUTTON_FOUND" = "1" ]; then
    echo "== tap the PDF button (retry up to 3x until PdfExportActivity starts) =="
    for attempt in 1 2 3; do
      if tap_text "تصدير PDF"; then
        BUTTON_TAPPED=1
        sleep 6
        adb -s "$DEV" logcat -d > artifacts/logcat-aftertap.txt 2>&1 || true
        if grep -qi "PdfExportActivity" artifacts/logcat-aftertap.txt; then
          echo "BUTTON TAP (attempt $attempt): PdfExportActivity started (in logcat)"
          break
        else
          echo "BUTTON TAP (attempt $attempt): PdfExportActivity NOT seen yet; re-dumping and retrying"
          dump_ui "retap-$attempt" >/dev/null 2>&1
        fi
      else
        echo "tap_text failed on attempt $attempt"
      fi
    done
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-aftertap.png 2>/dev/null || true
    if ! grep -qi "PdfExportActivity" artifacts/logcat-aftertap.txt 2>/dev/null; then
      echo "BUTTON TAP: PdfExportActivity NEVER started after 3 attempts"
    fi
    if grep -qi "PdfExportActivity" artifacts/logcat-aftertap.txt 2>/dev/null; then
      echo "== wait up to 300s for the system print dialog =="
      for w in $(seq 1 30); do
        sleep 10
        dump_ui "printwait-$w" >/dev/null 2>&1
        # print dialog markers: printer picker / Save as PDF / Print button
        if grep -qiE "Save as PDF|Print|طابعة|حفظ" "artifacts/ui-printwait-$w.xml" 2>/dev/null; then
          # confirm it is the print dialog (has a printer / save affordance), not the app
          if grep -qiE "Save as PDF" "artifacts/ui-printwait-$w.xml" 2>/dev/null; then
            PRINT_DIALOG=1
            echo "PRINT DIALOG APPEARED after ~$((w * 10))s"
            adb -s "$DEV" exec-out screencap -p > artifacts/screen-printdialog.png 2>/dev/null || true
            cp "artifacts/ui-printwait-$w.xml" artifacts/ui-printdialog.xml
            break
          fi
        fi
        if [ $((w % 6)) = 0 ]; then echo "  waited $((w * 10))s, no print dialog yet"; adb -s "$DEV" exec-out screencap -p > artifacts/screen-wait-$w.png 2>/dev/null || true; fi
      done
      if [ "$PRINT_DIALOG" = "1" ]; then
        echo "== try Save as PDF via the print dialog =="
        # Tap "Save as PDF" if it is a selectable printer row, then the save/print button.
        tap_text "Save as PDF" || echo "Save-as-PDF row tap failed (may already be selected)"
        sleep 3
        dump_ui printdialog2 >/dev/null 2>&1
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-printdialog2.png 2>/dev/null || true
        # The dialog's confirm button is usually a checkmark / SAVE / print icon.
        tap_text "SAVE" || tap_text "Save" || tap_text "حفظ" || echo "no SAVE button text found; trying bottom-right tap"
        sleep 5
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-aftersave.png 2>/dev/null || true
        dump_ui aftersave >/dev/null 2>&1
        # Look for a saved PDF in Download (system print spooler saves there when Save as PDF is picked).
        echo "== look for a saved PDF on device =="
        adb -s "$DEV" shell "ls -la /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null; ls -la /sdcard/Download/Kolnovel/ 2>/dev/null" | tee artifacts/pdflist.txt || true
        PDFFILE=$(adb -s "$DEV" shell "ls -t /sdcard/Download/*.pdf 2>/dev/null | head -1" | tr -d '
')
        if [ -n "$PDFFILE" ]; then
          echo "PDF FOUND on device: $PDFFILE"
          adb -s "$DEV" pull "$PDFFILE" artifacts/exported.pdf 2>&1 | tail -1
          if [ -f artifacts/exported.pdf ]; then PDF_SAVED=1; ls -la artifacts/exported.pdf; fi
        else
          echo "NO PDF in /sdcard/Download yet"
        fi
      else
        echo "PRINT DIALOG did NOT appear within 300s"
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-noprintdialog.png 2>/dev/null || true
      fi
    fi
  fi
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
if grep -qi "FATAL EXCEPTION" artifacts/logcat-final.txt; then echo "FATAL found"; else echo "no FATAL"; fi
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true

{
  echo "RESULT: install_ok=$INSTALL_OK button_found=$BUTTON_FOUND button_tapped=$BUTTON_TAPPED print_dialog=$PRINT_DIALOG pdf_saved=$PDF_SAVED"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
