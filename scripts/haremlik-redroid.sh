#!/usr/bin/env bash
# Haremlik Al-Sultan (Game of Sultans) ORIGINAL APK on Redroid (arm64 Android
# userspace, NO KVM) — runtime BASELINE test, in parallel with the mod build.
# App: com.dc.hwsj v66780401/7.804, launcher com.dc.angry.gen.StartupActivity,
# Solar2D (Corona) 3718.4701, label "Game of Sultans".
# Critical question: the base APK contains ZERO native .so files. Manifest
# says com.android.vending.splits.required=true,
# requiredSplitTypes="base__abi,base__density" — the Solar2D native runtime
# (libcorona.so) lives in the ABI split, which is NOT in this file.
# This run establishes empirically whether the base alone installs and
# launches on real arm64, or dies (INSTALL_FAILED_MISSING_SPLIT at install,
# or UnsatisfiedLinkError / missing libcorona at launch).
# APK source: GitHub release asset (262 MB, too big for a git push):
#   https://github.com/Omar08263/oscartv-smoke-ci/releases/download/haremlik-original-7.804/haremlik-original.apk
# sha256 5c6ac832f1200e189cc6cc15432be1acb97745d0b5c2a3017e0bd194a824d96d
# NO sign-in, NO purchase — stop at the login/home screen and report it.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK_URL="https://github.com/Omar08263/oscartv-smoke-ci/releases/download/haremlik-original-7.804/haremlik-original.apk"
APK="haremlik-original.apk"
APK_SHA256="5c6ac832f1200e189cc6cc15432be1acb97745d0b5c2a3017e0bd194a824d96d"
APK_SIZE=262435198
PKG="com.dc.hwsj"
ACT="com.dc.hwsj/com.dc.angry.gen.StartupActivity"
DEV="localhost:5555"
INSTALL_OK=0
LOG_OK=0

echo "== host =="
uname -m
nproc; free -h | head -2; df -h . | tail -1
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
adb --version | head -1 || echo "adb STILL MISSING"

echo "== download APK from release asset =="
curl -L --retry 3 --retry-delay 10 -o "$APK" "$APK_URL" 2>&1 | tail -3
ls -la "$APK" 2>&1
ACTUAL_SIZE=$(stat -c%s "$APK" 2>/dev/null || echo 0)
echo "expected size $APK_SIZE, actual $ACTUAL_SIZE"
if [ "$ACTUAL_SIZE" != "$APK_SIZE" ]; then
  echo "APK SIZE MISMATCH — download incomplete or wrong file"
  echo "RESULT: APK_DOWNLOAD_FAILED" > artifacts/RESULT.md
  exit 1
fi
echo "$APK_SHA256  $APK" | sha256sum -c - 2>&1 || { echo "SHA256 MISMATCH"; exit 1; }

echo "== kernel modules (binder/ashmem) =="
ls /dev/binder* /dev/ashmem 2>&1 || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder_linux modprobe FAILED (may be built-in or absent)"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem_linux modprobe FAILED (may be built-in or absent)"
ls -l /dev/binder* /dev/ashmem 2>&1 || echo "NO binder/ashmem devices after modprobe"

echo "== pull Redroid arm64 image =="
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -5
docker image inspect redroid/redroid:13.0.0-latest --format '{{.Architecture}} {{.Os}}' 2>&1

echo "== start Redroid =="
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
echo "device mounts:$MOUNTS"
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
docker ps --filter name=redroid --format '{{.Status}} {{.Image}}' 2>&1
docker logs redroid 2>&1 | tail -20 || true

echo "== wait for adb + boot_completed (up to 600s) =="
BOOT_OK=0
for i in $(seq 1 60); do
  adb connect "$DEV" >/dev/null 2>&1 || true
  if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
  fi
  sleep 10
done
if [ "$BOOT_OK" != "1" ]; then
  echo "REDROID DID NOT BOOT in 600s"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  adb -s "$DEV" shell getprop 2>&1 | head -20 || true
  echo "RESULT: REDROID_BOOT_FAILED" > artifacts/RESULT.md
  exit 1
fi

echo "== device identity (must be arm64) =="
adb -s "$DEV" shell getprop ro.product.cpu.abi
adb -s "$DEV" shell getprop ro.build.version.release
adb -s "$DEV" shell getprop ro.product.model
adb -s "$DEV" shell uname -m

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if ! grep -q "Success" artifacts/install.log; then
  echo "install attempt 1 failed, retrying once after 30s"
  sleep 30
  adb -s "$DEV" install -r -g "$APK" 2>&1 | tee -a artifacts/install.log
fi
if grep -q "Success" artifacts/install.log; then
  INSTALL_OK=1
  echo "INSTALL: SUCCESS"
else
  echo "INSTALL: FAILED"
fi
adb -s "$DEV" shell pm path "$PKG" 2>&1 | tee -a artifacts/install.log || true
adb -s "$DEV" shell dumpsys package "$PKG" 2>/dev/null | grep -E "versionCode|versionName|split" | head -10 || true
adb -s "$DEV" shell dumpsys package "$PKG" 2>/dev/null | grep -iE "splits|splitNames" | head -5 || true

if [ "$INSTALL_OK" = "1" ]; then
  echo "== launch StartupActivity =="
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
  echo "== 15s: early state =="
  sleep 15
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 15s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-15s.png 2>/dev/null || true
  ls -la artifacts/screen-15s.png 2>&1 || true
  echo "== wait to 60s total =="
  sleep 45
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 60s (crashed or exited)"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" shell dumpsys activity activities 2>/dev/null | grep -i -A2 "hwsj\|angry" | head -20 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-60s.png 2>/dev/null || true
  ls -la artifacts/screen-60s.png 2>&1 || true
fi

echo "== capture logcat =="
adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || echo "logcat -d FAILED"
adb -s "$DEV" logcat -d -b crash > artifacts/logcat-crash.txt 2>&1 || true
adb -s "$DEV" root 2>&1 || true
adb -s "$DEV" shell ls -la /data/tombstones/ 2>&1 | tee artifacts/tombstones.txt || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
if [ -s artifacts/logcat.txt ]; then LOG_OK=1; fi
wc -l artifacts/logcat.txt artifacts/logcat-crash.txt 2>&1 || true

echo "== FATAL / missing-native-lib scan =="
grep -i -B2 -A40 "FATAL EXCEPTION" artifacts/logcat.txt > artifacts/fatal.txt 2>/dev/null || true
grep -i -E "UnsatisfiedLinkError|libcorona|missing.*split|INSTALL_FAILED_MISSING_SPLIT|dlopen failed|library .* not found|No implementation found|System\.loadLibrary" artifacts/logcat.txt > artifacts/native-lib-lines.txt 2>/dev/null || true
grep -i -E "Corona|Solar2D|com\.ansca" artifacts/logcat.txt | head -40 > artifacts/corona-lines.txt 2>/dev/null || true
if [ -s artifacts/fatal.txt ]; then
  echo "FATAL EXCEPTION FOUND:"
  cat artifacts/fatal.txt
else
  echo "no FATAL EXCEPTION in logcat"
fi
if [ -s artifacts/native-lib-lines.txt ]; then
  echo "NATIVE-LIB / SPLIT LINES FOUND:"
  cat artifacts/native-lib-lines.txt
else
  echo "no native-lib/split error lines in logcat"
fi

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no) native_lib_error=$([ -s artifacts/native-lib-lines.txt ] && echo yes || echo no)"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK (original, sha256 $APK_SHA256)"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
