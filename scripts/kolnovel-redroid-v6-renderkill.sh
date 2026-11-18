#!/usr/bin/env bash
# Kolnovel v6 FINAL - Renderer-death guard test (problem 2, Case B3).
# The v6 failpaths2 B2 run (44322850418) did NOT test the guard: the dead-proxy
# cut never took effect (the export succeeded via auto-save), so no renderer
# died. This run tests the guard DETERMINISTICALLY: start a 401-ch export,
# wait for the print WebView's renderer process to appear, KILL it with
# kill -9, and check the app survives. Without the guard (v5), Chromium
# deliberately SIGTRAPs the app ("Render process's crash wasn't handled by
# all associated webviews"). With the guard (v6 onRenderProcessGone -> true),
# the app must stay alive and fail cleanly (toast, no app SIGTRAP, no FATAL).
# Expected: app_alive=YES, app_fatal=NO, guard_fired=YES (onRenderProcessGone
# in logcat OR the clean-fail toast path taken).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0
RENDERER_PID=""
GUARD_FIRED="NO"

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
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

echo "== install APK (v6) =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15

if [ "$INSTALL_OK" = "1" ]; then
  echo "== dismiss consent / skip onboarding =="
  dump_ui launch
  tap_text "Consent" || tap_text "consent" || echo "no Consent button"
  sleep 5
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || echo "no skip/next"
  sleep 5

  echo "== B3: export novel 76237 (401 ch), then kill the renderer mid-print =="
  adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
  sleep 3
  adb connect "$DEV" >/dev/null 2>&1 || true
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 76237 -e title "test" 2>&1 | tee artifacts/b3-start.log || true
  echo "== poll up to 5 min for the WebView renderer process =="
  for i in $(seq 1 60); do
    RENDERER_PID=$(adb -s "$DEV" shell "ps -A -o PID,NAME 2>/dev/null | grep -i 'sandboxed_process' | head -1 | awk '{print \$1}'" 2>/dev/null | tr -d '\r\n ')
    if [ -n "$RENDERER_PID" ]; then
      echo "renderer process found: pid=$RENDERER_PID after ~$((i * 5))s"
      break
    fi
    sleep 5
  done
  if [ -z "$RENDERER_PID" ]; then
    echo "RENDERER NEVER APPEARED (no print WebView started?) — aborting"
    echo "RESULT: install_ok=$INSTALL_OK renderer_found=NO" | tee artifacts/RESULT.md
  else
    echo "renderer pid=$RENDERER_PID; waiting 8s (let onLayout/onWrite start), then kill -9"
    sleep 8
    adb -s "$DEV" shell kill -9 "$RENDERER_PID" 2>&1 | tee artifacts/kill.log || echo "kill FAILED"
    echo "killed renderer pid=$RENDERER_PID at $(date -u +%H:%M:%S)"
    sleep 15
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-afterkill.png 2>/dev/null || true
    adb -s "$DEV" logcat -d > artifacts/logcat-afterkill.txt 2>&1 || true
    dump_ui afterkill >/dev/null 2>&1
    if adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
      echo "B3: app process ALIVE after renderer kill (GOOD — guard held)"
      echo "app_alive=YES" >> artifacts/RESULT.md
    else
      echo "B3: app process GONE after renderer kill (BAD — guard did not hold)"
      echo "app_alive=NO" >> artifacts/RESULT.md
    fi
    if grep -i "lah.KolNovelApp" artifacts/logcat-afterkill.txt 2>/dev/null | grep -qi "Fatal signal\|FATAL EXCEPTION"; then
      echo "B3: APP FATAL found (BAD)"; echo "app_fatal=YES" >> artifacts/RESULT.md
    else
      echo "B3: no APP FATAL (GOOD)"; echo "app_fatal=NO" >> artifacts/RESULT.md
    fi
    if grep -qi "Render process.*crash wasn't handled" artifacts/logcat-afterkill.txt 2>/dev/null; then
      echo "B3: renderer-death FATAL found (BAD — guard did not catch it)"
      echo "renderer_fatal=YES" >> artifacts/RESULT.md
    else
      echo "B3: no renderer-death FATAL (GOOD)"; echo "renderer_fatal=NO" >> artifacts/RESULT.md
    fi
    if grep -qi "onServiceDisconnected\|Renderer process.*crash detected" artifacts/logcat-afterkill.txt 2>/dev/null; then
      echo "B3: renderer death observed in logcat (the kill landed)"
      echo "renderer_died=YES" >> artifacts/RESULT.md
    else
      echo "B3: no renderer-death marker in logcat (kill may have missed?)"
      echo "renderer_died=NO" >> artifacts/RESULT.md
    fi
    # The guard's clean-fail path shows our Arabic toast text in the UI dump.
    if grep -qi "توقف محرك العرض\|تعذّر إنشاء PDF" artifacts/ui-afterkill.xml 2>/dev/null; then
      echo "B3: clean-fail toast visible (guard fired)"
      GUARD_FIRED="YES"
    fi
    echo "guard_fired=$GUARD_FIRED" >> artifacts/RESULT.md
    echo "renderer_pid=$RENDERER_PID" >> artifacts/RESULT.md
  fi
fi

echo "== final logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
{
  echo "RESULT: install_ok=$INSTALL_OK"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee -a artifacts/RESULT.md
docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
