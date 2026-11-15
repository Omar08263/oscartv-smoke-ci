#!/usr/bin/env bash
# Haremlik Al-Sultan MOD APK v3 + re-signed PAD1 asset pack (install-time split)
# on Redroid (arm64 Android userspace, NO KVM) — PAD1 SPLIT TEST: does
# `adb install-multiple` (v3 base + PAD1) install, launch, and REACH THE
# LOGIN SCREEN? v3 alone (run 43705039971) installed, Corona started, login
# scene started — but died at subpackagePart.lua:162 (nil subPackName) because
# the sprite assets/pack/effect/start_light.png (127,242 B) exists ONLY in
# PAD1.apk, the Play install-time asset pack (1.42 GB, 25,937 files under
# assets/assets/, split='PAD1', versionCode 66780401). The game was DESIGNED
# to be installed as base + PAD1 split. PAD1 was re-signed with OUR keystore
# (splits must share the base's signing key; same cert SHA-256 as v3).
# App: com.dc.hwsj v66780401/7.804 MOD, launcher com.dc.angry.gen.StartupActivity,
# Solar2D (Corona) 3718.4701, label "Game of Sultans".
# VIP patch: client-side VIP 16 (dataMod/roleMod/_vipMod/vipLogic); real premium
# stays server-side. This run proves install-multiple + launch (no FATAL) +
# login screen reached (subPackName error gone).
# APK sources: GitHub release assets on tag haremlik-mod-7.804-v3 (too big for
# a git push), downloaded via the Releases API with GITHUB_TOKEN (repo is
# private — the anonymous browser_download_url 404s; run 43696314975 proved that).
# TAP-TO-START (kept from run 43707233559): run 43706400720 reached the
# "Tap to start" screen at 60 s; this run waits to 75 s, taps center-screen
# (tap 2 at lower-center only if the screen is unchanged 15 s after tap 1),
# then screenshots at +30/+90/+150 s. That run reached CHARACTER CREATION
# (5 female portraits, name "Lou Howe", "Start your reign" bottom-center) —
# there is NO login form on a fresh install; the game goes straight to
# character creation (anonymous/guest flow).
# START-YOUR-REIGN (kept from run 43708060655): after the tap-to-start
# screenshots, locate "Start your reign" via uiautomator dump (fallback: tap
# 360,1195 on the 720x1280 display), tap it ONCE. That run reached the opening
# STORY cutscene (rainy Ottoman cityscape, Prince Selim text, gold "»" button
# bottom-right ~680,1235) which does NOT auto-advance.
# STORY-WALK (this run): starting ~30 s after the "Start your reign" tap,
# REPEAT up to 20x: tap "»" (680,1235), wait 15 s, screenshot screen-story-N.png.
# Stop early on a big top-of-frame scene change (new scene/home) or if a
# "Skip" button appears (tap it ONCE instead). Then screen-home.png; if home
# was reached, tap a profile/avatar button ONCE (uiautomator node if present,
# else the top-left avatar area ~70,90) and screenshot screen-profile.png to
# check for a VIP level/badge. If all 20 taps leave the story, stop and report.
# NEVER tap anything labeled price/purchase/recharge/top-up/VIP purchase.
# NO sign-in, NO account binding, NO payment info, NO age verification.
# v3 sha256 486e97c7620b821bcf9bbfd1607d40157a14ce4c1941546c2277492a6a9dc7f5
# PAD1 sha256 5061d7f48b834d09932d5040d3bfba761fa184b4fbe76cb93a3dc9c0e184816a
# NO sign-in, NO purchase — stop at the login/home screen and report it.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="Haremlik-v7.804-premium-v3.apk"
APK_SHA256="486e97c7620b821bcf9bbfd1607d40157a14ce4c1941546c2277492a6a9dc7f5"
APK_SIZE=291620338
PAD1="Haremlik-v7.804-PAD1-resigned.apk"
PAD1_SHA256="5061d7f48b834d09932d5040d3bfba761fa184b4fbe76cb93a3dc9c0e184816a"
PAD1_SIZE=1421381979
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

echo "== download APKs from release assets (private repo: API + GITHUB_TOKEN) =="
# Anonymous browser_download_url 404s on a private repo — download the assets
# via the Releases API with the workflow's GITHUB_TOKEN (same-repo access).
python3 - <<'PYEOF'
import json, os, urllib.request
tok = os.environ["GH_TOKEN"]
req = urllib.request.Request(
    "https://api.github.com/repos/Omar08263/oscartv-smoke-ci/releases/tags/haremlik-mod-7.804-v3",
    headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json"})
rel = json.load(urllib.request.urlopen(req))
for name in ("Haremlik-v7.804-premium-v3.apk", "Haremlik-v7.804-PAD1-resigned.apk"):
    asset = next(a for a in rel["assets"] if a["name"] == name)
    print("asset id:", asset["id"], "size:", asset["size"], "name:", name)
    req = urllib.request.Request(
        f"https://api.github.com/repos/Omar08263/oscartv-smoke-ci/releases/assets/{asset['id']}",
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/octet-stream"})
    with urllib.request.urlopen(req) as r, open(name, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    print("downloaded bytes:", os.path.getsize(name), "name:", name)
PYEOF
ls -la "$APK" "$PAD1" 2>&1
ACTUAL_SIZE=$(stat -c%s "$APK" 2>/dev/null || echo 0)
echo "expected base size $APK_SIZE, actual $ACTUAL_SIZE"
if [ "$ACTUAL_SIZE" != "$APK_SIZE" ]; then
  echo "APK SIZE MISMATCH — download incomplete or wrong file"
  echo "RESULT: APK_DOWNLOAD_FAILED" > artifacts/RESULT.md
  exit 1
fi
echo "$APK_SHA256  $APK" | sha256sum -c - 2>&1 || { echo "SHA256 MISMATCH (base)"; exit 1; }
ACTUAL_PAD1_SIZE=$(stat -c%s "$PAD1" 2>/dev/null || echo 0)
echo "expected PAD1 size $PAD1_SIZE, actual $ACTUAL_PAD1_SIZE"
if [ "$ACTUAL_PAD1_SIZE" != "$PAD1_SIZE" ]; then
  echo "PAD1 SIZE MISMATCH — download incomplete or wrong file"
  echo "RESULT: PAD1_DOWNLOAD_FAILED" > artifacts/RESULT.md
  exit 1
fi
echo "$PAD1_SHA256  $PAD1" | sha256sum -c - 2>&1 || { echo "SHA256 MISMATCH (PAD1)"; exit 1; }

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

echo "== install base + PAD1 split (install-multiple) =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install-multiple -r -g "$APK" "$PAD1" 2>&1 | tee artifacts/install.log
if ! grep -q "Success" artifacts/install.log; then
  echo "install-multiple attempt 1 failed, retrying once after 30s"
  sleep 30
  adb -s "$DEV" install-multiple -r -g "$APK" "$PAD1" 2>&1 | tee -a artifacts/install.log
fi
if grep -q "Success" artifacts/install.log; then
  INSTALL_OK=1
  echo "INSTALL-MULTIPLE: SUCCESS"
else
  echo "INSTALL-MULTIPLE: FAILED"
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
  echo "== TAP-TO-START: wait to 75s, tap center, screenshots at +30/+90/+150s =="
  sleep 15
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at 75s"
  SIZE=$(adb -s "$DEV" shell wm size 2>/dev/null | tr -d '\r')
  echo "display size: $SIZE" | tee -a artifacts/launch.log
  W=$(echo "$SIZE" | grep -o '[0-9]*x[0-9]*' | cut -dx -f1)
  H=$(echo "$SIZE" | grep -o '[0-9]*x[0-9]*' | cut -dx -f2)
  CX=$((W / 2)); CY=$((H / 2))
  LX=$((W / 2)); LY=$((H * 3 / 4))
  echo "tap 1: center $CX,$CY (display ${W}x${H})" | tee -a artifacts/launch.log
  adb -s "$DEV" shell input tap "$CX" "$CY" 2>&1 || true
  echo "tap 1 sent at ~75s after launch"
  sleep 15
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-tap+15s.png 2>/dev/null || true
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  # Did the screen change after tap 1? Compare with the pre-tap 60s shot.
  if cmp -s artifacts/screen-60s.png artifacts/screen-tap+15s.png; then
    echo "screen UNCHANGED 15s after tap 1 — tap 2 at lower-center $LX,$LY" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$LX" "$LY" 2>&1 || true
    echo "tap 2 sent" | tee -a artifacts/launch.log
  else
    echo "screen CHANGED after tap 1 — no second tap" | tee -a artifacts/launch.log
  fi
  echo "== post-tap screenshots at +30s / +90s / +150s after tap 1 =="
  sleep 15
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at tap+30s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-tap+30s.png 2>/dev/null || true
  ls -la artifacts/screen-tap+30s.png 2>&1 || true
  sleep 60
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at tap+90s"
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-tap+90s.png 2>/dev/null || true
  ls -la artifacts/screen-tap+90s.png 2>&1 || true
  sleep 60
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at tap+150s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-tap+150s.png 2>/dev/null || true
  ls -la artifacts/screen-tap+150s.png 2>&1 || true
  echo "== START-YOUR-REIGN: character-creation screen should be up; tap 'Start your reign' ONCE =="
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-reign-pre.png 2>/dev/null || true
  ls -la artifacts/screen-reign-pre.png 2>&1 || true
  # Fallback coords: button bottom-center, ~360,1195 on the 720x1280 display
  # (seen in run 43707233559 screenshots). Prefer uiautomator when it finds it.
  REIGN_X=$((W / 2)); REIGN_Y=$((H * 1195 / 1280))
  echo "reign fallback coords: $REIGN_X,$REIGN_Y (display ${W}x${H})" | tee -a artifacts/launch.log
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump.xml 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" pull /sdcard/window_dump.xml artifacts/uiautomator-reign-pre.xml 2>&1 || true
  if [ -s artifacts/uiautomator-reign-pre.xml ]; then
    REIGN_BOUNDS=$(grep -i "Start your reign" artifacts/uiautomator-reign-pre.xml | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 | sed 's/bounds="//; s/"//' || true)
    echo "uiautomator 'Start your reign' bounds: ${REIGN_BOUNDS:-<not found>}" | tee -a artifacts/launch.log
    if [ -n "$REIGN_BOUNDS" ]; then
      REIGN_X=$(echo "$REIGN_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[0])+int(a[2]))//2)")
      REIGN_Y=$(echo "$REIGN_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[1])+int(a[3]))//2)")
      echo "reign tap coords from uiautomator: $REIGN_X,$REIGN_Y" | tee -a artifacts/launch.log
    fi
  else
    echo "uiautomator dump empty/missing — using fallback coords" | tee -a artifacts/launch.log
  fi
  echo "tap START YOUR REIGN once at $REIGN_X,$REIGN_Y" | tee -a artifacts/launch.log
  adb -s "$DEV" shell input tap "$REIGN_X" "$REIGN_Y" 2>&1 || true
  echo "reign tap sent (ONE tap only)"
  echo "== STORY WALK: starting ~30s after the reign tap, tap the gold '»' advance button (680,1235) up to 20x =="
  sleep 30
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at reign+30s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-reign+30s.png 2>/dev/null || true
  ls -la artifacts/screen-reign+30s.png 2>&1 || true
  # Story advance button coords, scaled from the known 720x1280 layout
  # (gold "»" bottom-right, ~680,1235 in run 43708060655).
  STORY_X=$((W * 680 / 720)); STORY_Y=$((H * 1235 / 1280))
  echo "story advance '»' coords: $STORY_X,$STORY_Y (display ${W}x${H})" | tee -a artifacts/launch.log
  STORY_TAPS=0
  STORY_ENDED=no
  HOME_REACHED=no
  PROFILE_TAPPED=no
  PREV_SHOT="artifacts/screen-reign+30s.png"
  # Scene-change detector: the rain animation changes a few pixels between
  # frames, and each story page only changes the text box (bottom of frame);
  # a NEW scene changes most of the frame. Compare the TOP 60% of both shots
  # downscaled to 72x48 grayscale; mean abs diff > 10 (of 255) = new scene.
  # Falls back to PNG file-size delta > 20% when PIL is unavailable.
  cat > /tmp/scene_diff.py <<'PYEOF'
import sys
try:
    from PIL import Image
    a = Image.open(sys.argv[1]).convert("L")
    b = Image.open(sys.argv[2]).convert("L")
    w, h = a.size
    a = a.crop((0, 0, w, int(h * 0.6))).resize((72, 48))
    b = b.crop((0, 0, w, int(h * 0.6))).resize((72, 48))
    pa, pb = list(a.getdata()), list(b.getdata())
    diff = sum(abs(x - y) for x, y in zip(pa, pb)) / len(pa)
    print("BIG" if diff > 10 else "SAME")
    print("mean_abs_diff=%.2f" % diff, file=sys.stderr)
except ImportError:
    import os
    sa, sb = os.path.getsize(sys.argv[1]), os.path.getsize(sys.argv[2])
    print("BIG" if abs(sa - sb) / max(sa, 1) > 0.20 else "SAME")
except Exception as e:
    print("diff-error: %s" % e, file=sys.stderr)
    print("SAME")
PYEOF
  for N in $(seq 1 20); do
    # "Skip" check FIRST: if a Skip button ever appears (uiautomator exposes
    # zero Corona nodes, so this almost certainly never fires), tap it ONCE
    # instead of the "»" button and stop the loop.
    adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_skip.xml 2>&1 | tee -a artifacts/launch.log || true
    adb -s "$DEV" pull /sdcard/window_dump_skip.xml artifacts/uiautomator-story-$N.xml 2>&1 || true
    SKIP_BOUNDS=$(grep -i "skip" artifacts/uiautomator-story-$N.xml 2>/dev/null | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 | sed 's/bounds="//; s/"//' || true)
    if [ -n "$SKIP_BOUNDS" ]; then
      SKIP_X=$(echo "$SKIP_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[0])+int(a[2]))//2)")
      SKIP_Y=$(echo "$SKIP_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[1])+int(a[3]))//2)")
      echo "story tap $N/20: 'Skip' button found at $SKIP_X,$SKIP_Y — tapping it ONCE instead of '»'" | tee -a artifacts/launch.log
      adb -s "$DEV" shell input tap "$SKIP_X" "$SKIP_Y" 2>&1 || true
      STORY_TAPS=$((STORY_TAPS + 1))
      sleep 15
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-story-$N.png 2>/dev/null || true
      STORY_ENDED=yes
      break
    fi
    echo "story tap $N/20 at $STORY_X,$STORY_Y" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$STORY_X" "$STORY_Y" 2>&1 || true
    STORY_TAPS=$((STORY_TAPS + 1))
    sleep 15
    adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || { echo "app process NOT running after story tap $N — stopping the loop"; break; }
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-story-$N.png 2>/dev/null || true
    ls -la artifacts/screen-story-$N.png 2>&1 || true
    DIFF=$(python3 /tmp/scene_diff.py "$PREV_SHOT" "artifacts/screen-story-$N.png" 2>/dev/null || echo SAME)
    echo "story tap $N: scene-diff vs previous shot = $DIFF" | tee -a artifacts/launch.log
    if [ "$DIFF" = "BIG" ]; then
      echo "screen changed substantially after story tap $N — story scene left (new scene/home?)" | tee -a artifacts/launch.log
      STORY_ENDED=yes
      break
    fi
    PREV_SHOT="artifacts/screen-story-$N.png"
  done
  echo "story walk done: taps=$STORY_TAPS story_ended=$STORY_ENDED" | tee -a artifacts/launch.log
  echo "== final screenshots (screen-home.png) =="
  sleep 5
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at final screenshot"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-home.png 2>/dev/null || true
  ls -la artifacts/screen-home.png 2>&1 || true
  HOME_DIFF=$(python3 /tmp/scene_diff.py "$PREV_SHOT" artifacts/screen-home.png 2>/dev/null || echo SAME)
  echo "screen-home.png scene-diff vs last story shot = $HOME_DIFF" | tee -a artifacts/launch.log
  if [ "$STORY_ENDED" = "yes" ] || [ "$HOME_DIFF" = "BIG" ]; then
    HOME_REACHED=yes
  fi
  echo "home_reached (heuristic: big scene change after the story walk; verify visually from screen-home.png): $HOME_REACHED" | tee -a artifacts/launch.log
  # PROFILE CHECK — only if home was reached. Prefer a uiautomator
  # profile/avatar node; else tap the top-left avatar area ONCE
  # (~70,90 on 720x1280). Never tap price/purchase/recharge/top-up/VIP nodes.
  # If the story never ended, NO profile tap happens (do not tap blindly).
  if [ "$HOME_REACHED" = "yes" ]; then
    adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_home.xml 2>&1 | tee -a artifacts/launch.log || true
    adb -s "$DEV" pull /sdcard/window_dump_home.xml artifacts/uiautomator-home.xml 2>&1 || true
    PROF_BOUNDS=""
    if [ -s artifacts/uiautomator-home.xml ]; then
      PROF_BOUNDS=$(grep -i -E "profile|avatar" artifacts/uiautomator-home.xml | grep -v -i -E "price|purchase|recharge|top.up|vip|pay|buy|pack|gem|diamond|coin" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1 | sed 's/bounds="//; s/"//' || true)
      echo "uiautomator profile/avatar bounds: ${PROF_BOUNDS:-<none found>}" | tee -a artifacts/launch.log
    else
      echo "uiautomator dump at home empty/missing — using top-left avatar estimate" | tee -a artifacts/launch.log
    fi
    if [ -n "$PROF_BOUNDS" ]; then
      PROF_X=$(echo "$PROF_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[0])+int(a[2]))//2)")
      PROF_Y=$(echo "$PROF_BOUNDS" | python3 -c "import sys,re; a=re.findall(r'\d+',sys.stdin.read()); print((int(a[1])+int(a[3]))//2)")
    else
      PROF_X=$((W * 70 / 720)); PROF_Y=$((H * 90 / 1280))
      echo "no profile node — tapping top-left avatar area ONCE at $PROF_X,$PROF_Y" | tee -a artifacts/launch.log
    fi
    echo "tap PROFILE/AVATAR once at $PROF_X,$PROF_Y" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$PROF_X" "$PROF_Y" 2>&1 || true
    PROFILE_TAPPED=yes
    sleep 10
    adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after profile tap"
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-profile.png 2>/dev/null || true
    ls -la artifacts/screen-profile.png 2>&1 || true
  else
    echo "home NOT reached after $STORY_TAPS story taps — no profile tap" | tee -a artifacts/launch.log
  fi
  echo "profile_tapped=$PROFILE_TAPPED" | tee -a artifacts/launch.log
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
grep -i -E "subPackName|subpackagePart|start_light" artifacts/logcat.txt > artifacts/subpack-lines.txt 2>/dev/null || true
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

echo "== screen-change heuristics (verify visually from the screenshots) =="
LOGIN_REACHED=no
REIGN_REACHED=no
if [ -s artifacts/screen-home.png ] && [ -s artifacts/screen-60s.png ]; then
  if ! cmp -s artifacts/screen-60s.png artifacts/screen-home.png; then LOGIN_REACHED=yes; fi
fi
if [ -s artifacts/screen-reign+30s.png ] && [ -s artifacts/screen-tap+150s.png ]; then
  if ! cmp -s artifacts/screen-tap+150s.png artifacts/screen-reign+30s.png; then REIGN_REACHED=yes; fi
fi
echo "login_reached (heuristic: final screenshot differs from pre-tap shot; verify visually): $LOGIN_REACHED"
echo "reign_reached (heuristic: screen-reign+30s.png differs from screen-tap+150s.png, i.e. left character creation): $REIGN_REACHED"
echo "story_taps: ${STORY_TAPS:-0} story_ended: ${STORY_ENDED:-no} home_reached: ${HOME_REACHED:-no}"
echo "profile_tapped: ${PROFILE_TAPPED:-no}"

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no) native_lib_error=$([ -s artifacts/native-lib-lines.txt ] && echo yes || echo no) subpack_error=$([ -s artifacts/subpack-lines.txt ] && echo yes || echo no) login_reached=$LOGIN_REACHED reign_reached=$REIGN_REACHED story_taps=${STORY_TAPS:-0} story_ended=${STORY_ENDED:-no} home_reached=${HOME_REACHED:-no} profile_tapped=${PROFILE_TAPPED:-no} vip_visible=unknown"
  echo "login_reached is a heuristic (screen-home.png differs from screen-60s.png); confirm from the screenshots"
  echo "reign_reached is a heuristic (screen-reign+30s.png differs from screen-tap+150s.png); confirm from the screenshots"
  echo "home_reached is a heuristic (big top-of-frame scene change after the story walk); confirm from screen-home.png"
  echo "story_taps counts '»' advance taps (+1 if a Skip button was tapped instead on the final iteration)"
  echo "vip_visible=unknown: the script cannot read pixels — the operator determines VIP from screen-home.png and screen-profile.png (look for a VIP level/badge, e.g. 'VIP 16', on the home/profile screen)"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK (MOD VIP16+arm64 libs, sha256 $APK_SHA256) + $PAD1 (re-signed PAD1 split, sha256 $PAD1_SHA256) via install-multiple"
} | tee artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
