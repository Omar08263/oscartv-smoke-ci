#!/usr/bin/env bash
# Kolnovel v6 - Reflection auto-save test on Redroid (arm64, NO KVM) — problem 4, attempt 1.
# Installs the ReflectTest APK (a minimal app that tries direct
# PrintDocumentAdapter onLayout/onWrite via sun.misc.Unsafe-allocated
# callback instances), launches it, waits for the verdict, and pulls the
# result file + logcat. The verdict line is:
#   REFLECT_AUTO_SAVE=POSSIBLE: real PDF written via direct onLayout/onWrite
# or
#   REFLECT_AUTO_SAVE=IMPOSSIBLE: <exact reason>
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/ReflectTest-v1.apk"
PKG="com.kolnovel.reflecttest"
ACT="com.kolnovel.reflecttest/.MainActivity"
DEV="localhost:5555"
INSTALL_OK=0

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

echo "== install ReflectTest APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi

if [ "$INSTALL_OK" = "1" ]; then
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
  echo "== wait up to 150s for the verdict =="
  for i in $(seq 1 30); do
    sleep 5
    adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || true
    if grep -q "REFLECT_AUTO_SAVE=" artifacts/logcat.txt 2>/dev/null; then
      echo "verdict seen after ~$((i * 5))s"; break
    fi
    if ! adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then
      echo "app finished (pid gone) after ~$((i * 5))s"; sleep 3; break
    fi
  done
  adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-final.png 2>/dev/null || true
  echo "== ReflectTest log lines =="
  grep "ReflectTest" artifacts/logcat.txt | sed 's/^.*ReflectTest *: //' | tee artifacts/reflect-log.txt || echo "(no ReflectTest lines in logcat)"
  echo "== pull result file + test PDF =="
  adb -s "$DEV" shell "ls -la /sdcard/Android/data/$PKG/files/ 2>/dev/null" | tee artifacts/files.txt || true
  adb -s "$DEV" pull "/sdcard/Android/data/$PKG/files/reflect-result.txt" artifacts/reflect-result.txt 2>&1 | tail -1 || true
  adb -s "$DEV" pull "/sdcard/Android/data/$PKG/files/reflect-test.pdf" artifacts/reflect-test.pdf 2>&1 | tail -1 || true
  if [ -f artifacts/reflect-test.pdf ]; then
    ls -la artifacts/reflect-test.pdf
    head -c 8 artifacts/reflect-test.pdf | od -c | head -2
    echo "pdf_head: $(head -c 5 artifacts/reflect-test.pdf)"
  else echo "no reflect-test.pdf pulled"; fi
  grep -h "REFLECT_AUTO_SAVE=" artifacts/reflect-result.txt artifacts/logcat.txt 2>/dev/null | head -3 | tee artifacts/VERDICT.txt || echo "NO VERDICT FOUND" | tee artifacts/VERDICT.txt
fi

docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
{
  echo "RESULT: install_ok=$INSTALL_OK"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md
docker rm -f redroid >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
