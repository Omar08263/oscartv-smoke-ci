#!/usr/bin/env bash
# فضاء الروايات (Novels Space) — fetch the missing arm64 ABI split APK via
# Aurora Store (anonymous login, no Google account) on Redroid (arm64 Android
# userspace, NO KVM) — same proven boot pattern as haremlik-redroid.sh.
#
# App: com.fadariwyat.cenele v3.0.0 versionCode 59 (developer AYDspace).
# The base APK we already hold (32,538,938 B, sha256 b8fbe051...) is base-only
# with ZERO .so files. All Dart logic (incl. the premium/VIP gate) lives in
# libapp.so inside the missing config.arm64_v8a.apk split. This run fetches
# that split so the Dart gate can be analysed. NOT a mod build.
#
# WARNING — wrong-package trap: APKPure lists a DIFFERENT app also called
# «فضاء الروايات», package zxc.laitooo.flutter.riwayat_space v1.0.1.
# That is NOT our app. Every gate below checks com.fadariwyat.cenele + v59.
#
# Flow: boot Redroid -> install Aurora Store 4.8.4 (F-Droid, verified sha256)
# -> anonymous login via UI automation (uiautomator dump + tap) -> open the
# app page via market://details deep link -> Install -> pull the installed
# split APKs off the device (pm path + adb pull, Redroid is rootable) ->
# hard verification gates -> artifacts + RESULT.md.
# No sign-in, no purchase, no Google account.
set -u
mkdir -p artifacts splits
exec > >(tee artifacts/run.log) 2>&1

PKG="com.fadariwyat.cenele"
EXPECTED_BASE_SHA256="b8fbe051b4c88a4b0e2ffc92509820c3c93cdaa859cefa5b4a775cb939d5ac82"
EXPECTED_BASE_SIZE=32538938
EXPECTED_VERSION_CODE=59
EXPECTED_VERSION_NAME="3.0.0"
AURORA_PKG="com.aurora.store"
AURORA_URL="https://f-droid.org/repo/com.aurora.store_76.apk"
AURORA_SHA256="fd9c75d90d0f4a7c132b9b4a5a2cf1992a45e03b8d8ff988b7dcfbc0db2c4d11"
AURORA_SIZE=9360088
AURORA_VERSION_CODE=76
DEV="localhost:5555"

fail() { echo "RESULT: $1" | tee artifacts/RESULT.md; exit 1; }

echo "== host =="
uname -m
nproc; free -h | head -2; df -h . | tail -1
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
command -v aapt >/dev/null || sudo apt-get install -y -qq aapt unzip 2>&1 | tail -2 || echo "apt aapt install FAILED"
command -v unzip >/dev/null || sudo apt-get install -y -qq unzip 2>&1 | tail -2 || true
adb --version | head -1 || echo "adb STILL MISSING"
aapt version 2>&1 | head -1 || echo "aapt STILL MISSING"

echo "== download Aurora Store 4.8.4 (F-Droid, official build) =="
curl -sL --max-time 120 -o aurora-store.apk "$AURORA_URL" || fail "AURORA_DOWNLOAD_FAILED"
ls -la aurora-store.apk
ACTUAL_SIZE=$(stat -c%s aurora-store.apk 2>/dev/null || echo 0)
echo "expected size $AURORA_SIZE, actual $ACTUAL_SIZE"
[ "$ACTUAL_SIZE" = "$AURORA_SIZE" ] || fail "AURORA_SIZE_MISMATCH"
echo "$AURORA_SHA256  aurora-store.apk" | sha256sum -c - || fail "AURORA_SHA256_MISMATCH"
aapt dump badging aurora-store.apk 2>/dev/null | head -1 | tee artifacts/aurora-badging.txt
grep -q "name='$AURORA_PKG' versionCode='$AURORA_VERSION_CODE'" artifacts/aurora-badging.txt \
  || fail "AURORA_NOT_GENUINE (badging mismatch — not com.aurora.store v76)"
echo "Aurora Store verified: com.aurora.store 4.8.4 (76), sha256 OK"

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
  fail "REDROID_BOOT_FAILED"
fi

echo "== device identity (must be arm64) =="
adb -s "$DEV" shell getprop ro.product.cpu.abi
adb -s "$DEV" shell getprop ro.build.version.release
adb -s "$DEV" shell getprop ro.product.model
adb -s "$DEV" shell uname -m

echo "== install Aurora Store on Redroid =="
adb -s "$DEV" install -r -g aurora-store.apk 2>&1 | tee artifacts/aurora-install.log
grep -q "Success" artifacts/aurora-install.log || fail "AURORA_INSTALL_FAILED"
adb -s "$DEV" shell pm list packages | grep "$AURORA_PKG" || fail "AURORA_PKG_NOT_LISTED"
adb -s "$DEV" shell dumpsys package "$AURORA_PKG" 2>/dev/null | grep -E "versionCode|versionName" | head -3
# Let Aurora install apps without the unknown-sources prompt, and give it storage.
adb -s "$DEV" shell appops set --uid "$AURORA_PKG" REQUEST_INSTALL_PACKAGES allow 2>&1 || true
adb -s "$DEV" shell pm grant "$AURORA_PKG" android.permission.READ_EXTERNAL_STORAGE 2>&1 || true
adb -s "$DEV" shell pm grant "$AURORA_PKG" android.permission.WRITE_EXTERNAL_STORAGE 2>&1 || true
adb -s "$DEV" shell pm grant "$AURORA_PKG" android.permission.POST_NOTIFICATIONS 2>&1 || true

# ---------- UI automation helpers ----------
# ui_dump: pull current hierarchy to artifacts/ui-<tag>.xml + printable text list.
ui_dump() {
  local tag="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  adb -s "$DEV" pull /sdcard/window_dump.xml "artifacts/ui-$tag.xml" >/dev/null 2>&1 || true
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$tag.png" 2>/dev/null || true
  python3 - "artifacts/ui-$tag.xml" <<'PYEOF' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print("  [ui parse failed]", e); sys.exit(0)
texts = []
for n in root.iter("node"):
    t = (n.get("text") or "").strip()
    d = (n.get("content-desc") or "").strip()
    if t: texts.append(t)
    elif d: texts.append("[" + d + "]")
print("  UI texts:", " | ".join(texts[:60]))
PYEOF
}

# tap_text <pattern>: tap centre of first node whose text/content-desc matches
# (case-insensitive substring). Prints TAP x y or NOTAP. Never matches a node
# containing "google" unless the pattern itself says google (avoid the
# Google-sign-in button when we want anonymous).
tap_text() {
  local pattern="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  adb -s "$DEV" pull /sdcard/window_dump.xml /tmp/window_dump.xml >/dev/null 2>&1 || { echo NOTAP; return 1; }
  local xy
  xy=$(python3 - "$pattern" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
pat = sys.argv[1].lower()
try:
    root = ET.parse("/tmp/window_dump.xml").getroot()
except Exception:
    sys.exit(1)
for n in root.iter("node"):
    t = (n.get("text") or "")
    d = (n.get("content-desc") or "")
    hay = (t + " " + d).lower()
    if pat in hay and n.get("clickable") == "true":
        if "google" in hay and "google" not in pat:
            continue
        b = n.get("bounds") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            sys.exit(0)
sys.exit(1)
PYEOF
)
  if [ -n "$xy" ]; then
    echo "TAP '$pattern' at $xy"
    # shellcheck disable=SC2086
    adb -s "$DEV" shell input tap $xy
    return 0
  fi
  echo "NOTAP '$pattern'"
  return 1
}

# ui_has <pattern>: 0 if any node text/content-desc contains pattern (ci).
ui_has() {
  local pattern="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  adb -s "$DEV" pull /sdcard/window_dump.xml /tmp/window_dump.xml >/dev/null 2>&1 || return 1
  python3 - "$pattern" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
pat = sys.argv[1].lower()
try:
    root = ET.parse("/tmp/window_dump.xml").getroot()
except Exception:
    sys.exit(1)
for n in root.iter("node"):
    hay = ((n.get("text") or "") + " " + (n.get("content-desc") or "")).lower()
    if pat in hay:
        sys.exit(0)
sys.exit(1)
PYEOF
}

echo "== launch Aurora Store =="
adb -s "$DEV" shell am start -W -n "$AURORA_PKG/com.aurora.store.MainActivity" 2>&1 | tail -5 || \
  adb -s "$DEV" shell monkey -p "$AURORA_PKG" -c android.intent.category.LAUNCHER 1 2>&1 | tail -3
sleep 5
ui_dump aurora-00-launch

echo "== Aurora onboarding: drive to ANONYMOUS login (up to ~25 steps) =="
# Aurora 4.8.4 onboarding: welcome -> account choice (Google / Anonymous) ->
# permissions. We tap in priority order; "anonymous" first, never Google.
# Loop ends when the main screen appears (Search/Updates/Apps tabs) or we run
# out of steps. Every step is dumped + screenshotted for diagnosis.
ONBOARD_OK=0
for step in $(seq 1 25); do
  ui_dump "aurora-onboard-$step"
  if ui_has "anonymous"; then
    tap_text "anonymous" && { sleep 4; continue; }
  fi
  if ui_has "search" && ui_has "updates"; then
    echo "Aurora main screen reached at step $step"
    ONBOARD_OK=1; break
  fi
  # Dismiss update/notice dialogs first so they never block the flow.
  if tap_text "later"; then sleep 2; continue; fi
  if tap_text "not now"; then sleep 2; continue; fi
  if tap_text "cancel"; then sleep 2; continue; fi
  if tap_text "continue"; then sleep 4; continue; fi
  if tap_text "next"; then sleep 3; continue; fi
  if tap_text "skip"; then sleep 3; continue; fi
  if tap_text "allow"; then sleep 3; continue; fi
  if tap_text "got it"; then sleep 2; continue; fi
  if tap_text "agree"; then sleep 3; continue; fi
  if tap_text "accept"; then sleep 3; continue; fi
  if tap_text "ok"; then sleep 2; continue; fi
  if tap_text "sign in"; then sleep 4; continue; fi
  echo "onboarding step $step: no known button found, waiting 5s"
  sleep 5
done
if [ "$ONBOARD_OK" != "1" ]; then
  # One last check: maybe we are already on the main screen but the tab
  # labels differ (Compose builds vary). Check for the search affordance.
  if ui_has "search"; then
    echo "main screen assumed (search affordance present)"
    ONBOARD_OK=1
  else
    ui_dump aurora-onboard-stuck
    echo "AURORA ONBOARDING STUCK — see artifacts/ui-aurora-onboard-*.xml + screen-*.png"
    docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
    adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || true
    fail "AURORA_ONBOARDING_STUCK"
  fi
fi

echo "== open Novels Space app page via market:// deep link =="
adb -s "$DEV" shell am start -a android.intent.action.VIEW \
  -d "market://details?id=$PKG" "$AURORA_PKG" 2>&1 | tail -3
sleep 8
ui_dump aurora-app-page
# The deep link must land on OUR package. Aurora shows the package name on the
# app page (details section). If the page shows the WRONG app, abort.
if ui_has "zxc.laitooo"; then
  echo "WRONG APP PAGE — zxc.laitooo.flutter.riwayat_space detected, aborting"
  fail "WRONG_PACKAGE_PAGE"
fi
if ui_has "$PKG"; then
  echo "app page shows our package $PKG"
else
  echo "WARNING: package name not visible on app page text; proceeding — the Install gate below checks the installed package"
fi

echo "== tap Install / Download =="
INSTALL_TAPPED=0
for attempt in 1 2 3; do
  if tap_text "install"; then INSTALL_TAPPED=1; break; fi
  if tap_text "download"; then INSTALL_TAPPED=1; break; fi
  if tap_text "get"; then INSTALL_TAPPED=1; break; fi
  echo "install button not found, attempt $attempt — waiting 5s and re-dumping"
  sleep 5
  ui_dump "aurora-install-retry-$attempt"
done
[ "$INSTALL_TAPPED" = "1" ] || fail "AURORA_INSTALL_BUTTON_NOT_FOUND"
sleep 5
ui_dump aurora-after-install-tap

echo "== wait for install of $PKG (up to 600s) =="
INSTALLED=0
for i in $(seq 1 60); do
  if adb -s "$DEV" shell pm path "$PKG" 2>/dev/null | grep -q "package:"; then
    INSTALLED=1; echo "installed after ~$((i * 10))s"; break
  fi
  # Aurora may surface an error dialog (incompatible / not found / no account)
  if ui_has "not available" || ui_has "couldn't be downloaded" || ui_has "not compatible"; then
    ui_dump aurora-install-error
    echo "Aurora reports the app cannot be downloaded/installed"
    break
  fi
  sleep 10
done
ui_dump aurora-after-install-wait
adb -s "$DEV" shell pm path "$PKG" 2>&1 | tee artifacts/pm-path.txt || true
if [ "$INSTALLED" != "1" ]; then
  echo "target package never appeared via pm path"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || true
  fail "AURORA_INSTALL_NEVER_COMPLETED"
fi

echo "== pull installed split APKs off the device =="
adb -s "$DEV" root 2>&1 || true
sleep 2
adb -s "$DEV" shell pm path "$PKG" 2>&1 | tee artifacts/pm-path.txt
# pm path lines look like: package:/data/app/~~abc/com.fadariwyat.cenele-xyz/base.apk
# and: package:/data/app/~~abc/com.fadariwyat.cenele-xyz/split_config.arm64_v8a.apk
grep "^package:" artifacts/pm-path.txt | sed 's/^package://' > /tmp/device-apk-paths.txt || true
cat /tmp/device-apk-paths.txt
PULLED=0
while IFS= read -r devpath; do
  [ -n "$devpath" ] || continue
  fname=$(basename "$devpath")
  echo "pulling $devpath -> splits/$fname"
  if adb -s "$DEV" pull "$devpath" "splits/$fname" 2>&1 | tail -1; then
    PULLED=$((PULLED + 1))
  fi
done < /tmp/device-apk-paths.txt
echo "pulled $PULLED file(s) via pm path"
ls -la splits/

# Fallback / supplement: Aurora's download directory may still hold the files.
adb -s "$DEV" shell ls -laR /sdcard/Aurora/Store/Downloads/ 2>/dev/null | tee artifacts/aurora-downloads-listing.txt || true
if ! ls splits/split_config.arm64_v8a.apk >/dev/null 2>&1; then
  echo "arm64 split NOT in pm-path pull — trying Aurora download dir"
  adb -s "$DEV" shell find /sdcard/Aurora -iname "*cenele*" 2>/dev/null | tee artifacts/aurora-cenele-files.txt || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    adb -s "$DEV" pull "$f" "splits/$(basename "$f")" 2>&1 | tail -1 || true
  done < artifacts/aurora-cenele-files.txt
  ls -la splits/
fi
# Also: any split APK anywhere under /sdcard mentioning the package.
adb -s "$DEV" shell find /sdcard -iname "*arm64*" -name "*.apk" 2>/dev/null | head -20 | tee artifacts/sdcard-arm64-apks.txt || true

echo "== verification gates =="
ls -la splits/
[ -f splits/base.apk ] || fail "BASE_APK_MISSING (pm path pull produced no base.apk)"
[ -f splits/split_config.arm64_v8a.apk ] || fail "ARM64_SPLIT_MISSING (no split_config.arm64_v8a.apk pulled)"

BASE_SIZE=$(stat -c%s splits/base.apk)
BASE_SHA=$(sha256sum splits/base.apk | cut -d' ' -f1)
SPLIT_SIZE=$(stat -c%s splits/split_config.arm64_v8a.apk)
SPLIT_SHA=$(sha256sum splits/split_config.arm64_v8a.apk | cut -d' ' -f1)
echo "base.apk: size=$BASE_SIZE sha256=$BASE_SHA"
echo "split_config.arm64_v8a.apk: size=$SPLIT_SIZE sha256=$SPLIT_SHA"

aapt dump badging splits/base.apk 2>/dev/null | head -1 | tee artifacts/base-badging.txt
grep -q "name='$PKG' versionCode='$EXPECTED_VERSION_CODE' versionName='$EXPECTED_VERSION_NAME'" artifacts/base-badging.txt \
  || fail "BASE_BADGING_MISMATCH (not com.fadariwyat.cenele v59/3.0.0)"
echo "base badging OK: $PKG v$EXPECTED_VERSION_CODE/$EXPECTED_VERSION_NAME"

if [ "$BASE_SHA" != "$EXPECTED_BASE_SHA256" ]; then
  echo "base sha256 MISMATCH: got $BASE_SHA expected $EXPECTED_BASE_SHA256"
  fail "BASE_SHA256_MISMATCH"
fi
if [ "$BASE_SIZE" != "$EXPECTED_BASE_SIZE" ]; then
  echo "base size MISMATCH: got $BASE_SIZE expected $EXPECTED_BASE_SIZE"
  fail "BASE_SIZE_MISMATCH"
fi
echo "base sha256 + size MATCH the known original exactly"

unzip -l splits/split_config.arm64_v8a.apk | tee artifacts/split-contents.txt
grep -q "lib/arm64-v8a/libapp.so" artifacts/split-contents.txt \
  || fail "LIBAPP_SO_MISSING (split has no lib/arm64-v8a/libapp.so)"
echo "arm64 split CONTAINS lib/arm64-v8a/libapp.so"

# Extra evidence: split badging + libapp.so size.
aapt dump badging splits/split_config.arm64_v8a.apk 2>/dev/null | head -1 | tee artifacts/split-badging.txt || true
unzip -l splits/split_config.arm64_v8a.apk | grep "lib/arm64-v8a/libapp.so" | tee artifacts/libapp-line.txt
mkdir -p artifacts/splits
cp splits/base.apk splits/split_config.arm64_v8a.apk artifacts/splits/ 2>/dev/null || true
# Copy any other splits pulled (density etc.) too.
for f in splits/*.apk; do cp "$f" artifacts/splits/ 2>/dev/null || true; done
ls -la artifacts/splits/

echo "== capture logs =="
adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || echo "logcat -d FAILED"
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true

{
  echo "RESULT: SUCCESS"
  echo "app: com.fadariwyat.cenele v3.0.0 (versionCode 59) — فضاء الروايات (Novels Space)"
  echo "source: Aurora Store 4.8.4 (com.aurora.store v76) anonymous login, on Redroid arm64"
  echo "base.apk: size=$BASE_SIZE sha256=$BASE_SHA (MATCHES known original)"
  echo "split_config.arm64_v8a.apk: size=$SPLIT_SIZE sha256=$SPLIT_SHA (contains lib/arm64-v8a/libapp.so)"
  echo "libapp.so: $(grep -o 'lib/arm64-v8a/libapp.so' artifacts/libapp-line.txt | head -1) — see artifacts/split-contents.txt for size"
  echo "other splits pulled: $(ls splits/ | tr '\n' ' ')"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE: split APKs fetched and verified"
exit 0
