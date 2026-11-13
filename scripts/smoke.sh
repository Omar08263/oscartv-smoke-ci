#!/usr/bin/env bash
# OscarTV mod smoke test: install, launch, screenshot, UI dump,
# best-effort profile/ad-free navigation + premium text check, crash scan.
set -u
mkdir -p artifacts
APK="app/OscarTV-v1.1.6-premium.apk"
PKG="com.drama.mp4"
ACT="com.drama.mp4.ui.splash.SplashActivity"

echo "== installing APK =="
adb install -r "$APK" | tee artifacts/install.log

echo "== launching $ACT =="
adb shell am start -n "$ACT"
sleep 25
adb shell screencap -p /sdcard/home.png
adb pull /sdcard/home.png artifacts/home.png
adb shell uiautomator dump /sdcard/ui-home.xml
adb pull /sdcard/ui-home.xml artifacts/ui-home.xml
adb logcat -d > artifacts/logcat.txt || true

echo "== profile/ad-free navigation + premium check (best effort) =="
python3 scripts/check_premium.py || true

echo "== crash scan =="
if grep -q "FATAL EXCEPTION" artifacts/logcat.txt; then
  echo "CRASH FOUND" | tee artifacts/verdict.txt
  grep -A15 "FATAL EXCEPTION" artifacts/logcat.txt | head -40 >> artifacts/verdict.txt
else
  echo "NO FATAL CRASH in logcat" | tee -a artifacts/verdict.txt
fi
echo "== done =="
ls -la artifacts/
