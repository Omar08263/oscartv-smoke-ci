#!/usr/bin/env bash
# Snapchat clean-mod v2 (13.70.0.49) on Redroid (arm64 Android userspace, NO KVM).
# App: com.snapchat.android v1370049/13.70.0.49, launcher com.snap.mushroom.MainActivity.
# v2 fixes (vs v1, which redirected to a betting site on launch):
#  - update/redirect channel dead: caverock v/w/y deleted; k/q/g/s/d/FMNotification
#    neutered; dobhac rewrite trap removed; DevMsg remote channel deleted (5 files)
#    + FMSC.after_setContentViewV2 neutered; killOpen + ApkSignatureKillerEx URL
#    removed; REQUEST_INSTALL_PACKAGES removed; versionCode truthful 1370049.
#  - VM setCtx hijack neutralized: 3 guard flips in libfmmodsp.so (t.me/FouadMODS
#    + startActivity + System.exit now unreachable) + 9 feature-default flips
#    false->true (HideReadMsg, HideSnapView, HideTyping x2, HideOnlineBitmoji,
#    iOS emoji/font x2, changeLoc_active, UnlimitedViewTime(dead)).
#  - Ads: gk.c() forced false; rC3 16-key guard (5 bools false, 11 URLs ->
#    127.0.0.1) in L()/o()/d()/v(); hardcoded ad hosts dead; screenshot watchman
#    (NUa/DJf/DW) killed; P3 chat media-view receipts dropped.
# APK source: GitHub release asset (194 MB, too big for a git push), downloaded
# via the Releases API with GITHUB_TOKEN.
# sha256 8aee606ebf02f45a27780c3de879bb05a066aab6470312e5951824205f3cfddf
# NO sign-in, NO purchase — stop at the login screen and report it.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="Snapchat-v13.70.0.49-clean-mod-v2.apk"
APK_SHA256="8aee606ebf02f45a27780c3de879bb05a066aab6470312e5951824205f3cfddf"
APK_SIZE=193977745
PKG="com.snapchat.android"
ACT="com.snapchat.android/com.snap.mushroom.MainActivity"
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

echo "== download APK from release asset (private repo: API + GITHUB_TOKEN) =="
python3 - <<'PYEOF'
import json, os, urllib.request
tok = os.environ["GH_TOKEN"]
req = urllib.request.Request(
    "https://api.github.com/repos/Omar08263/oscartv-smoke-ci/releases/tags/snapchat-clean-mod-v2",
    headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json"})
rel = json.load(urllib.request.urlopen(req))
asset = next(a for a in rel["assets"] if a["name"] == "Snapchat-v13.70.0.49-clean-mod-v2.apk")
print("asset id:", asset["id"], "size:", asset["size"])
req = urllib.request.Request(
    f"https://api.github.com/repos/Omar08263/oscartv-smoke-ci/releases/assets/{asset['id']}",
    headers={"Authorization": f"Bearer {tok}", "Accept": "application/octet-stream"})
with urllib.request.urlopen(req) as r, open("Snapchat-v13.70.0.49-clean-mod-v2.apk", "wb") as f:
    while True:
        chunk = r.read(1 << 20)
        if not chunk:
            break
        f.write(chunk)
print("downloaded bytes:", os.path.getsize("Snapchat-v13.70.0.49-clean-mod-v2.apk"))
PYEOF
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
adb -s "$DEV" shell dumpsys package "$PKG" 2>/dev/null | grep -E "versionCode|versionName" | head -3 || true

if [ "$INSTALL_OK" = "1" ]; then
  echo "== launch MainActivity =="
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
  echo "== 15s: early state =="
  sleep 15
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 15s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus\|mFocusedApp" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-15s.png 2>/dev/null || true
  ls -la artifacts/screen-15s.png 2>&1 || true
  echo "== wait to 60s total =="
  sleep 45
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 60s (crashed or exited)"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus\|mFocusedApp" | head -3 || true
  adb -s "$DEV" shell dumpsys activity activities 2>/dev/null | grep -i -A2 "snapchat\|mushroom" | head -20 || true
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

echo "== FATAL scan (app only) =="
grep -i -B2 -A40 "FATAL EXCEPTION" artifacts/logcat.txt > artifacts/fatal.txt 2>/dev/null || true
grep -i "AndroidRuntime" artifacts/logcat.txt | head -40 > artifacts/androidruntime-lines.txt 2>/dev/null || true
if [ -s artifacts/fatal.txt ]; then
  echo "FATAL EXCEPTION FOUND:"
  cat artifacts/fatal.txt
else
  echo "no FATAL EXCEPTION in logcat"
fi

echo "== REDIRECT scan (the v1 failure: betting-site redirect on launch) =="
grep -i -E "t\.me|FouadMODS|SamMods|apkchatpro|45\.134\.173\.110|45\.134|/check|betting|casino|gambling" artifacts/logcat.txt > artifacts/redirect-lines.txt 2>/dev/null || true
grep -i -E "android\.intent\.action\.VIEW|START u0 .*cmp=(com\.android\.chrome|org\.chromium|com\.android\.browser)|Starting: Intent.*VIEW" artifacts/logcat.txt > artifacts/browser-intent-lines.txt 2>/dev/null || true
if [ -s artifacts/redirect-lines.txt ]; then
  echo "REDIRECT-RELATED LINES FOUND:"
  cat artifacts/redirect-lines.txt
else
  echo "no redirect-related lines in logcat"
fi
if [ -s artifacts/browser-intent-lines.txt ]; then
  echo "BROWSER-INTENT LINES FOUND:"
  cat artifacts/browser-intent-lines.txt
else
  echo "no browser-intent lines in logcat"
fi

echo "== AD-HOST scan (informational: ad requests that escaped the guards) =="
grep -i -E "snapads\.com|adserver\.snapchat|gcp\.api\.snapchat\.com.*ad" artifacts/logcat.txt | head -30 > artifacts/ad-lines.txt 2>/dev/null || true
if [ -s artifacts/ad-lines.txt ]; then
  echo "AD-HOST LINES FOUND:"
  cat artifacts/ad-lines.txt
else
  echo "no ad-host lines in logcat"
fi

echo "== SYSTEM EXIT scan (VM hijack ended in System.exit) =="
grep -i -E "System\.exit|Process .* has died|Force finishing activity.*snapchat" artifacts/logcat.txt | head -20 > artifacts/exit-lines.txt 2>/dev/null || true
if [ -s artifacts/exit-lines.txt ]; then
  echo "EXIT-RELATED LINES FOUND:"
  cat artifacts/exit-lines.txt
else
  echo "no exit-related lines in logcat"
fi

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no) redirect_lines=$([ -s artifacts/redirect-lines.txt ] && echo yes || echo no) browser_intent=$([ -s artifacts/browser-intent-lines.txt ] && echo yes || echo no) ad_lines=$([ -s artifacts/ad-lines.txt ] && echo yes || echo no)"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK (clean-mod v2, sha256 $APK_SHA256)"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
