#!/usr/bin/env bash
# Kolnovel v6 - Failure-path round 2 (problem 2, Case B2): REAL network loss
# mid-fetch. The v6 failpaths run PROVED airplane mode is a NO-OP on Redroid
# (run 44315957097: airplane_mode_on=1 set, broadcast denied, yet the 401-ch
# export reached the print dialog — Redroid's virtual ethernet is not
# affected by airplane mode). This run does what airplane mode was MEANT to
# do: kill the app's network while the export is fetching.
# Method (primary): iptables OUTPUT DROP for the app's UID (root shell).
# Fallback (if iptables is unavailable): point the global http_proxy at a
# dead address (127.0.0.1:9) — the mitm run proved the app honors the
# global proxy, so this fails every connection fast.
# Target: novel 76237 (401 ch). Cut at +8 s after start, wait 180 s.
# Expected (clean failure): error toast, NO print job, NO PDF, NO crash,
# PdfExportActivity finishes, app process alive.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0
CUT_METHOD="none"

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

echo "== install APK =="
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

  echo "== Case B2: export novel 76237 (401 ch), cut network at +8s =="
  APP_UID=$(adb -s "$DEV" shell dumpsys package "$PKG" 2>/dev/null | grep -m1 "userId=" | sed 's/[^0-9]//g')
  echo "app uid: ${APP_UID:-unknown}"
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 76237 -e title "test" 2>&1 | tee artifacts/caseB2-start.log || true
  sleep 8
  echo "cutting network now (fetch should be in progress)"
  adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
  sleep 3
  adb connect "$DEV" >/dev/null 2>&1 || true
  if [ -n "$APP_UID" ] && adb -s "$DEV" shell "iptables -A OUTPUT -m owner --uid-owner $APP_UID -j DROP && echo IPTABLES_OK" 2>&1 | tee artifacts/iptables.log | grep -q "IPTABLES_OK"; then
    CUT_METHOD="iptables-uid-drop"
    echo "network cut via iptables (uid $APP_UID)"
    adb -s "$DEV" shell "iptables -L OUTPUT -n | head -8" 2>&1 | tee -a artifacts/iptables.log || true
  else
    echo "iptables cut FAILED; fallback: dead proxy"
    adb -s "$DEV" shell settings put global http_proxy "127.0.0.1:9" 2>&1
    adb -s "$DEV" shell settings get global http_proxy 2>&1 | tee artifacts/proxy-state.txt || true
    CUT_METHOD="dead-proxy"
    echo "network cut via dead proxy (127.0.0.1:9)"
  fi
  echo "cut_method=$CUT_METHOD" | tee artifacts/CUT_METHOD.txt
  echo "== wait 180s for the clean failure =="
  sleep 180
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseB2.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseB2.txt 2>&1 || true
  adb -s "$DEV" shell dumpsys print > artifacts/dumpsys-caseB2.txt 2>&1 || true
  if grep -qi "print_job_id" artifacts/dumpsys-caseB2.txt 2>/dev/null; then
    echo "caseB2: PRINT JOB EXISTS (BAD)"; echo "caseB2_print_job=YES" >> artifacts/RESULT.md
  else
    echo "caseB2: no print job (GOOD)"; echo "caseB2_print_job=NO" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell "ls /sdcard/Download/Kolnovel/*.pdf /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null" | grep -q .; then
    echo "caseB2: PDF FILE EXISTS (BAD)"; echo "caseB2_pdf=YES" >> artifacts/RESULT.md
  else
    echo "caseB2: no PDF file (GOOD)"; echo "caseB2_pdf=NO" >> artifacts/RESULT.md
  fi
  # App-specific fatal check: the generic grep also matches the constant
  # bluetooth SIGABRT tombstones on Redroid (noise). The REAL signal is a
  # Fatal signal / FATAL EXCEPTION in OUR app (lah.KolNovelApp) or the
  # Chromium renderer-death FATAL ("Render process's crash wasn't handled").
  if grep -i "lah.KolNovelApp" artifacts/logcat-caseB2.txt 2>/dev/null | grep -qi "Fatal signal\|FATAL EXCEPTION"; then
    echo "caseB2: APP FATAL/SIGSEGV found (BAD)"; echo "caseB2_fatal=YES" >> artifacts/RESULT.md
  elif grep -qi "Render process.*crash wasn't handled" artifacts/logcat-caseB2.txt 2>/dev/null; then
    echo "caseB2: renderer-death FATAL found (BAD — guard did not catch it)"; echo "caseB2_fatal=YES" >> artifacts/RESULT.md
  else
    echo "caseB2: no APP FATAL (GOOD — bluetooth tombstones ignored)"; echo "caseB2_fatal=NO" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
    echo "caseB2: app process alive (GOOD)"
  else
    echo "caseB2: app process GONE (BAD)"; echo "caseB2_app_gone=YES" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell dumpsys activity activities 2>/dev/null | grep -qi "PdfExportActivity"; then
    echo "caseB2: PdfExportActivity still present (check screenshot: spinner or finished?)"
  else
    echo "caseB2: PdfExportActivity finished (GOOD)"
  fi
  echo "== restore network =="
  if [ "$CUT_METHOD" = "iptables-uid-drop" ]; then
    adb -s "$DEV" shell "iptables -D OUTPUT -m owner --uid-owner $APP_UID -j DROP" 2>&1 || true
  else
    adb -s "$DEV" shell settings put global http_proxy :0 2>&1 || true
  fi
  echo "cut_method=$CUT_METHOD" >> artifacts/RESULT.md
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
