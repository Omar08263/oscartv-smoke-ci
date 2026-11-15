#!/usr/bin/env bash
# Haremlik Al-Sultan MOD APK v4 + re-signed PAD1 asset pack (install-time split)
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
# APK sources: GitHub release assets on tag haremlik-mod-7.804-v4 (too big for
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
# REPEAT up to 40x: tap "»" (680,1235), wait 15 s, screenshot screen-story-N.png.
# Stop early on a big top-of-frame scene change (new scene/home) or if a
# "Skip" button appears (tap it ONCE instead). FIX (this run): PREV_SHOT is
# updated on the breaking iteration too, so the later home comparison is
# against the LAST story shot, not the previous one.
# RETRY (run 43711691091): walk 1 stopped after ONE tap — the scene-diff BIG
# break misfired: tap 1 went rainy-city -> bright forest hunt (Karaman: "Now
# the hunt truly begins, Your Highness!"), a normal story page, not home and
# not the decree. BIG only means "new background", and backgrounds change
# constantly in this story. The walk now NEVER breaks on scene-diff BIG.
# Instead it uses a pixel story-page detector: a normal story dialogue page
# has a light parchment text box at the bottom (bottom-strip mean luminance
# ~196-205, measured firsthand on reign+30s / story-1 / home.png of run
# 43711691091); the decree scroll page measures 26, title 33, char-creation
# 41. The loop taps "»" up to 20x and stops early ONLY when the page is no
# longer a story dialogue page (bottom strip dark, confirmed by a second
# screenshot 15 s later in case of a fade/transition). GOT IT fix VERIFIED in
# run 43711691091: parsed tap (552,401), banner GONE after tap 1, no 2nd tap.
# RESUME RUN (this run): story continues PAST the decree (run 43710283715: one
# center tap advanced the decree to ANOTHER story page, Piyale: "All hail the
# new Sultan!", with the "»" button back). So after the decree center-tap,
# RESUME the "»" story loop (up to 20 more taps, screen-story2-N.png) and stop
# early ONLY on a big scene change to a NON-story screen (scene-diff BIG).
# Walk 2 runs WHENEVER walk 1 ends still in dialogue (a story page with a "»"
# button) — NOT only when decree_advanced=yes (that gate starved walk 2 in
# runs 43711691091 + 43712648675, where walk 1 ran out of taps mid-story).
# home_reached=yes is set ONLY on that big scene change after the resumed walk
# (never from decree_advanced alone — that was the run 43710283715 false
# positive); the operator verifies home from screen-home.png pixels.
# DECREE PAGE (this run): the story walk ends on the final decree-scroll page
# ("I've decided to pass the throne to Eddy Good..."), which has NO "»"
# button. Screenshot it as screen-decree.png; if it is stable (no
# auto-advance), tap CENTER SCREEN (360,640) ONCE, wait 30 s, screenshot
# screen-decree+30s.png; if still on the decree page, wait a further 60 s and
# screenshot screen-decree+90s.png. Then screen-home.png; if home was reached,
# tap a profile/avatar button ONCE (uiautomator node if present, else the
# top-left avatar area ~70,90) and screenshot screen-profile.png to check for
# a VIP level/badge. If the decree page never advances after the center tap +
# 60 s wait, stop and report that (do not keep tapping blindly).
# OVERLAY DISMISS (this run): right after launch, once the 15 s screenshot
# shows the game loading, tap "GOT IT" on the Redroid "Viewing full screen"
# system overlay — parse the uiautomator dump WITH PYTHON/XML and take the
# bounds of the node whose text="GOT IT" (real bounds [464,353][640,449],
# center (552,401), verified in run 43710283715's uiautomator-overlay.xml).
# NEVER grep -o the first bounds on the one-line XML (that returned the root
# FrameLayout [0,0][720,1280] and both taps went to (360,640) in the last run).
# Fallback if parsing fails: tap the literal (552,401). Screenshot
# screen-overlay-dismiss.png and confirm the banner is GONE; tap once more
# if it is still there. The overlay covers the top ~500 px of every screenshot
# and swallows taps there — dismissing it early is what makes the top bar
# (avatar / VIP badge) visible and tappable at all.
# NEVER tap anything labeled price/purchase/recharge/top-up/VIP purchase.
# NO sign-in, NO account binding, NO payment info, NO age verification.
# v4 sha256 ce3edbf22373c92d1c1417c2c6acb8d8776149a523ceeba00cff8c9db3c63afa
# PAD1 sha256 5061d7f48b834d09932d5040d3bfba761fa184b4fbe76cb93a3dc9c0e184816a
# NO sign-in, NO purchase — stop at the login/home screen and report it.
# DYNREA BASELINE (this run): same APK/PAD1, same install + story walk as
# v4 — PLUS Frida live instrumentation. frida-server (android-arm64,
# version matched to the frida-tools client) is pushed to the Redroid
# device and started as root BEFORE launch; the baseline script
# scripts/frida/haremlik-dynrea-baseline.js (env FRIDA_SCRIPT) is attached
# to the app pid right after launch and logs PLAINTEXT gateway traffic via
# KSecureValidation.flip (dir=1 OUT = plaintext request, dir=0 IN =
# plaintext response) + KSInterceptor metadata. NO round-2 phase here:
# after home the run SOAKs (default 90 s, env SOAK_SECONDS) to capture
# home/idle traffic, then detaches. Sibling probe agents run their own
# Frida scripts on this same infra (see work/dynrea/infra/READY.md).
# NEVER tap purchase/claim/buy. NO sign-in, NO real-money purchase.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="Haremlik-v7.804-premium-v4.apk"
APK_SHA256="ce3edbf22373c92d1c1417c2c6acb8d8776149a523ceeba00cff8c9db3c63afa"
APK_SIZE=291689970
PAD1="Haremlik-v7.804-PAD1-resigned.apk"
PAD1_SHA256="5061d7f48b834d09932d5040d3bfba761fa184b4fbe76cb93a3dc9c0e184816a"
PAD1_SIZE=1421381979
PKG="com.dc.hwsj"
ACT="com.dc.hwsj/com.dc.angry.gen.StartupActivity"
DEV="localhost:5555"
FRIDA_SCRIPT="${FRIDA_SCRIPT:-scripts/frida/haremlik-dynrea-baseline.js}"
FRIDA_OK=0
FRIDA_ATTACHED=no
FRIDA_PID=""
# node_center <dump.xml> <text-substring> - prints "X Y" (center of the node
# whose text/content-desc contains the substring), using Python XML parsing.
# The uiautomator dump is a SINGLE line of XML, so grepping bounds returns
# the FIRST bounds in the file (root FrameLayout) - never grep for bounds.
node_center() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, xml.etree.ElementTree as ET, re
try:
    tree = ET.parse(sys.argv[1])
except Exception as e:
    print("PARSE_FAIL %s" % e, file=sys.stderr); sys.exit(1)
want = sys.argv[2].lower()
for el in tree.iter("node"):
    t = ((el.get("text") or "") + " " + (el.get("content-desc") or "")).lower()
    if want in t:
        m = re.findall(r"\d+", el.get("bounds") or "")
        if len(m) == 4:
            print((int(m[0]) + int(m[2])) // 2, (int(m[1]) + int(m[3])) // 2)
            sys.exit(0)
sys.exit(2)
PYEOF
}
# dismiss_consent <shot-prefix> — CONSENT-DISMISS (run 43755257265 blocker):
# a native Android dialog titled "Personalized Advertisement Statement"
# (Cancel / Agree) appears over "Tap to start" during loading, already present
# at 60s, and swallows every tap. uiautomator should expose the "Agree" node
# (reuse node_center); fallback tap is (546,882) on the 720x1280 display.
# Sets global CONSENT_DISMISSED: yes (dismissed, dialog gone on re-check),
# no (still present after two taps), not-present (no dialog in the dump).
# If the dialog is absent, records not-present (or keeps an earlier yes) and
# continues normally — never fails the run.
dismiss_consent() {
  local prefix="$1"
  local dump="artifacts/uiautomator-consent-$prefix.xml"
  local dump2="artifacts/uiautomator-consent-$prefix-2.xml"
  local dump3="artifacts/uiautomator-consent-$prefix-3.xml"
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_consent.xml 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" pull /sdcard/window_dump_consent.xml "$dump" 2>&1 || true
  if [ ! -s "$dump" ] || ! grep -qi -E "Agree|Personalized Advertisement" "$dump" 2>/dev/null; then
    echo "consent dialog NOT present in uiautomator dump ($prefix) — continuing normally" | tee -a artifacts/launch.log
    if [ "$CONSENT_DISMISSED" != "yes" ] && [ "$CONSENT_DISMISSED" != "no" ]; then
      CONSENT_DISMISSED=not-present
    fi
    return 0
  fi
  echo "consent dialog PRESENT ($prefix) — dismissing via 'Agree' node" | tee -a artifacts/launch.log
  local center=""
  center=$(node_center "$dump" "Agree" 2>/dev/null || true)
  local tx=546 ty=882
  if [ -n "$center" ]; then
    tx=$(echo "$center" | cut -d' ' -f1)
    ty=$(echo "$center" | cut -d' ' -f2)
    echo "uiautomator 'Agree' node center: tap $tx,$ty" | tee -a artifacts/launch.log
  else
    echo "no 'Agree' node parsed — tapping fallback coords $tx,$ty" | tee -a artifacts/launch.log
  fi
  adb -s "$DEV" shell input tap "$tx" "$ty" 2>&1 || true
  sleep 5
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$prefix.png" 2>/dev/null || true
  ls -la "artifacts/screen-$prefix.png" 2>&1 || true
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_consent2.xml 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" pull /sdcard/window_dump_consent2.xml "$dump2" 2>&1 || true
  if [ -s "$dump2" ] && grep -qi -E "Agree|Personalized Advertisement" "$dump2" 2>/dev/null; then
    echo "consent dialog STILL present after tap 1 ($prefix) — tapping fallback coords 546,882 once more" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap 546 882 2>&1 || true
    sleep 5
    adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$prefix-2.png" 2>/dev/null || true
    ls -la "artifacts/screen-$prefix-2.png" 2>&1 || true
    adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_consent3.xml 2>&1 | tee -a artifacts/launch.log || true
    adb -s "$DEV" pull /sdcard/window_dump_consent3.xml "$dump3" 2>&1 || true
    if [ -s "$dump3" ] && grep -qi -E "Agree|Personalized Advertisement" "$dump3" 2>/dev/null; then
      echo "consent dialog STILL present after tap 2 ($prefix) — recording consent_dismissed=no" | tee -a artifacts/launch.log
      CONSENT_DISMISSED=no
    else
      echo "consent dialog GONE after tap 2 ($prefix)" | tee -a artifacts/launch.log
      CONSENT_DISMISSED=yes
    fi
  else
    echo "consent dialog GONE after tap 1 ($prefix)" | tee -a artifacts/launch.log
    CONSENT_DISMISSED=yes
  fi
  echo "consent_dismissed=$CONSENT_DISMISSED ($prefix)" | tee -a artifacts/launch.log
}
CONSENT_DISMISSED=not-present
# --- FRIDA (dynrea) -------------------------------------------------------
# setup_frida_server: install frida-tools (pinned known-good 14.13.1 =
# frida client 17.26.3, verified in the local RE toolbox), download the
# MATCHING frida-server android-arm64 release, push it to the (rooted)
# Redroid device and start it. Sets FRIDA_OK=1 when frida-ps -U lists
# processes. Never aborts the run on failure — the RESULT.md frida fields
# record it and the run continues as a plain v4-style walk.
setup_frida_server() {
  echo "== FRIDA SETUP: frida-tools + matching frida-server android-arm64 =="
  if [ ! -f "$FRIDA_SCRIPT" ]; then
    echo "FRIDA SCRIPT MISSING: $FRIDA_SCRIPT — cannot attach"
    return 1
  fi
  if ! python3 -m pip --version >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq python3-pip python3-venv 2>&1 | tail -2 || echo "pip install FAILED"
  fi
  if python3 -m venv frida-venv 2>/dev/null; then
    # shellcheck disable=SC1091
    . frida-venv/bin/activate
    pip install -q "frida-tools==14.13.1" 2>&1 | tail -3 || pip install -q frida-tools 2>&1 | tail -3
  else
    echo "venv unavailable — falling back to pip --user --break-system-packages"
    python3 -m pip install -q --user --break-system-packages "frida-tools==14.13.1" 2>&1 | tail -3 || python3 -m pip install -q --user --break-system-packages frida-tools 2>&1 | tail -3
    export PATH="$HOME/.local/bin:$PATH"
  fi
  FRIDA_VER=$(python3 -c "import frida; print(frida.__version__)" 2>/dev/null || echo "")
  echo "frida client version (python frida lib): ${FRIDA_VER:-MISSING} (frida --version: $(frida --version 2>/dev/null || echo MISSING))"
  if [ -z "$FRIDA_VER" ]; then echo "frida import FAILED — no frida-server download"; return 1; fi
  curl -sSL --retry 3 -o frida-server.xz "https://github.com/frida/frida/releases/download/${FRIDA_VER}/frida-server-${FRIDA_VER}-android-arm64.xz" 2>&1 | tail -2 || true
  if [ ! -s frida-server.xz ]; then echo "frida-server DOWNLOAD FAILED for version $FRIDA_VER"; return 1; fi
  python3 -c "import lzma; d=lzma.decompress(open('frida-server.xz','rb').read()); open('frida-server','wb').write(d); print('frida-server decompressed bytes:', len(d))"
  ls -la frida-server
  adb -s "$DEV" root 2>&1 || true
  sleep 2
  adb connect "$DEV" >/dev/null 2>&1 || true
  echo "adb shell id (must be uid=0/root for frida-server to attach to the app):"
  adb -s "$DEV" shell id 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" push frida-server /data/local/tmp/frida-server 2>&1 | tail -2
  adb -s "$DEV" shell chmod 755 /data/local/tmp/frida-server 2>&1
  adb -s "$DEV" shell "nohup /data/local/tmp/frida-server >/data/local/tmp/frida-server.log 2>&1 &" 2>&1 || true
  sleep 3
  frida-ps -U > artifacts/frida-ps-before.log 2>&1 || true
  head -20 artifacts/frida-ps-before.log || true
  if grep -q "PID" artifacts/frida-ps-before.log; then
    FRIDA_OK=1
    echo "FRIDA-SERVER: up (frida-ps -U lists processes)"
  else
    echo "FRIDA-SERVER: frida-ps showed no process table — see artifacts/frida-ps-before.log"
  fi
}
# attach_frida: attach the FRIDA_SCRIPT to the app pid ASAP after launch
# (tight pidof poll so early login traffic is not missed). The frida CLI
# runs in the background, logging to artifacts/frida.log (-o). Sets
# FRIDA_ATTACHED=yes once frida.log shows ALL PRIMARY HOOKS ATTACHED.
attach_frida() {
  echo "== FRIDA ATTACH: $FRIDA_SCRIPT to $PKG =="
  if [ "$FRIDA_OK" != "1" ]; then echo "FRIDA ATTACH: skipped — frida-server is not up"; return 1; fi
  local pid="" i
  for i in $(seq 1 15); do
    pid=$(adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr -d ' ' || true)
    if [ -n "$pid" ]; then break; fi
    sleep 2
  done
  if [ -z "$pid" ]; then echo "FRIDA ATTACH: no app pid after 30s — cannot attach"; return 1; fi
  echo "app pid: $pid — attaching frida in the background (log artifacts/frida.log)"
  nohup frida -U -p "$pid" -l "$FRIDA_SCRIPT" -o artifacts/frida.log > artifacts/frida-stdout.log 2>&1 &
  FRIDA_PID=$!
  echo "frida client pid: $FRIDA_PID"
  sleep 10
  if grep -q "ALL PRIMARY HOOKS ATTACHED" artifacts/frida.log 2>/dev/null; then
    FRIDA_ATTACHED=yes
    echo "FRIDA ATTACH: hooks confirmed (ALL PRIMARY HOOKS ATTACHED in frida.log)"
  elif grep -q "dynrea baseline script loaded" artifacts/frida.log 2>/dev/null; then
    echo "FRIDA ATTACH: script loaded, hooks still attaching (retry window running) — re-checked at soak"
  else
    echo "FRIDA ATTACH: no [DYNREA][init] lines in frida.log after 10s — see artifacts/frida.log + artifacts/frida-stdout.log"
    tail -20 artifacts/frida-stdout.log 2>/dev/null || true
  fi
}
# stop_frida: detach the frida client so frida.log is complete before logcat.
stop_frida() {
  echo "== FRIDA STOP: detaching frida client pid ${FRIDA_PID:-<none>} =="
  if [ -n "$FRIDA_PID" ]; then
    kill "$FRIDA_PID" 2>/dev/null || true
    sleep 3
    kill -9 "$FRIDA_PID" 2>/dev/null || true
  fi
  frida-ps -U > artifacts/frida-ps-after.log 2>&1 || true
  sleep 2
  ls -la artifacts/frida.log artifacts/frida-stdout.log 2>&1 || true
  wc -l artifacts/frida.log 2>&1 || true
}
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
    "https://api.github.com/repos/Omar08263/oscartv-smoke-ci/releases/tags/haremlik-mod-7.804-v4",
    headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json"})
rel = json.load(urllib.request.urlopen(req))
for name in ("Haremlik-v7.804-premium-v4.apk", "Haremlik-v7.804-PAD1-resigned.apk"):
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

echo "== FRIDA SETUP (before install — server must be up before launch) =="
setup_frida_server || echo "FRIDA SETUP FAILED — continuing as a plain walk; frida fields in RESULT.md will show it"

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
  echo "== FRIDA ATTACH (immediately after launch, before the 15s check) =="
  attach_frida || echo "FRIDA ATTACH FAILED — continuing the walk without Frida; see artifacts/frida*.log"
  echo "== 15s: early state =="
  sleep 15
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 15s"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-15s.png 2>/dev/null || true
  ls -la artifacts/screen-15s.png 2>&1 || true
  echo "== OVERLAY DISMISS: Redroid 'Viewing full screen / GOT IT' banner covers the top ~500px and swallows taps there — dismiss it NOW =="
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_overlay.xml 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" pull /sdcard/window_dump_overlay.xml artifacts/uiautomator-overlay.xml 2>&1 || true
  GOTIT_CENTER=$(node_center artifacts/uiautomator-overlay.xml "GOT IT" 2>/dev/null || true)
  if [ -n "$GOTIT_CENTER" ]; then
    GOTIT_X=$(echo "$GOTIT_CENTER" | cut -d' ' -f1)
    GOTIT_Y=$(echo "$GOTIT_CENTER" | cut -d' ' -f2)
    echo "uiautomator 'GOT IT' node center (Python/XML parse): tap $GOTIT_X,$GOTIT_Y" | tee -a artifacts/launch.log
  else
    GOTIT_X=552; GOTIT_Y=401
    echo "no 'GOT IT' node parsed from dump — tapping literal fallback coords $GOTIT_X,$GOTIT_Y (verified bounds [464,353][640,449])" | tee -a artifacts/launch.log
  fi
  adb -s "$DEV" shell input tap "$GOTIT_X" "$GOTIT_Y" 2>&1 || true
  echo "GOT IT tap 1 sent" | tee -a artifacts/launch.log
  sleep 3
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-overlay-dismiss.png 2>/dev/null || true
  ls -la artifacts/screen-overlay-dismiss.png 2>&1 || true
  adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_overlay2.xml 2>&1 | tee -a artifacts/launch.log || true
  adb -s "$DEV" pull /sdcard/window_dump_overlay2.xml artifacts/uiautomator-overlay-2.xml 2>&1 || true
  if grep -qi "GOT IT" artifacts/uiautomator-overlay-2.xml 2>/dev/null; then
    echo "overlay banner STILL present after tap 1 — tapping GOT IT once more" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$GOTIT_X" "$GOTIT_Y" 2>&1 || true
    sleep 3
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-overlay-dismiss-2.png 2>/dev/null || true
    ls -la artifacts/screen-overlay-dismiss-2.png 2>&1 || true
  else
    echo "overlay banner GONE after tap 1 (no 'GOT IT' node in dump)" | tee -a artifacts/launch.log
  fi
  echo "== wait to 60s total =="
  sleep 45
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 60s (crashed or exited)"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" shell dumpsys activity activities 2>/dev/null | grep -i -A2 "hwsj\|angry" | head -20 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-60s.png 2>/dev/null || true
  ls -la artifacts/screen-60s.png 2>&1 || true
  echo "== CONSENT DISMISS: 'Personalized Advertisement Statement' dialog blocked run 43755257265 — dismiss it BEFORE tap-to-start =="
  dismiss_consent "consent-dismiss"
  echo "consent_dismissed=$CONSENT_DISMISSED (after 60s)" | tee -a artifacts/launch.log
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
    echo "screen UNCHANGED 15s after tap 1 — checking for the consent dialog before tap 2" | tee -a artifacts/launch.log
    dismiss_consent "consent-dismiss-tap"
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-tap+15s.png 2>/dev/null || true
    echo "screen-tap+15s.png re-captured after the consent check (consent_dismissed=$CONSENT_DISMISSED)" | tee -a artifacts/launch.log
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
    REIGN_CENTER=$(node_center artifacts/uiautomator-reign-pre.xml "Start your reign" 2>/dev/null || true)
    echo "uiautomator 'Start your reign' node center (Python/XML parse): ${REIGN_CENTER:-<not found>}" | tee -a artifacts/launch.log
    if [ -n "$REIGN_CENTER" ]; then
      REIGN_X=$(echo "$REIGN_CENTER" | cut -d' ' -f1)
      REIGN_Y=$(echo "$REIGN_CENTER" | cut -d' ' -f2)
      echo "reign tap coords from uiautomator: $REIGN_X,$REIGN_Y" | tee -a artifacts/launch.log
    fi
  else
    echo "uiautomator dump empty/missing — using fallback coords" | tee -a artifacts/launch.log
  fi
  echo "tap START YOUR REIGN once at $REIGN_X,$REIGN_Y" | tee -a artifacts/launch.log
  adb -s "$DEV" shell input tap "$REIGN_X" "$REIGN_Y" 2>&1 || true
  echo "reign tap sent (ONE tap only)"
  echo "== STORY WALK: starting ~30s after the reign tap, tap the gold '»' advance button (680,1235) up to 40x =="
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
  DETECTOR_FAILED=no
  HOME_REACHED=no
  PROFILE_TAPPED=no
  PREV_SHOT="artifacts/screen-reign+30s.png"
  # Scene-change detector: the rain animation changes a few pixels between
  # frames, and each story page only changes the text box (bottom of frame);
  # a NEW scene changes most of the frame. Compare the TOP 60% of both shots
  # downscaled to 72x48 grayscale; mean abs diff > 10 (of 255) = new scene.
  # STDLIB ONLY (zlib + struct PNG decoder in /tmp/pngmini.py) — the GitHub
  # runner has NO PIL, and the old PIL code + file-size fallback silently
  # masked that (runs 43711691091 + 43712648675). On ANY error the detector
  # exits non-zero and prints the error to stderr — NEVER a silent fallback.
  cat > /tmp/pngmini.py <<'PYEOF'
import struct, zlib

def _unfilter(raw, w, h, bpp, stride):
    # Returns rows as a list of bytearrays (unfiltered scanlines).
    rows = []
    prev = bytearray(stride)
    p = 0
    for _y in range(h):
        ftype = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ValueError("unknown PNG filter %d" % ftype)
        rows.append(line)
        prev = line
    return rows

def read_png(path):
    # Returns (width, height, channels, pixels) with 8-bit samples per
    # channel; palette images are expanded to RGB. No PIL, stdlib only.
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file: %s" % path)
    pos = 8
    idat = b""
    plte = None
    w = h = None
    bit_depth = color_type = interlace = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            w, h, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if interlace != 0:
                raise ValueError("interlaced PNG not supported: %s" % path)
            if bit_depth not in (8, 16):
                raise ValueError("unsupported PNG bit depth %d: %s" % (bit_depth, path))
        elif ctype == b"PLTE":
            plte = chunk
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if w is None:
        raise ValueError("no IHDR in PNG: %s" % path)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    bpp = channels * (bit_depth // 8)  # bytes per pixel for filtering
    stride = w * bpp
    raw = zlib.decompress(idat)
    if len(raw) < h * (stride + 1):
        raise ValueError("truncated PNG data: %s" % path)
    rows = _unfilter(raw, w, h, bpp, stride)
    px = bytearray(w * h * 3)
    for y, line in enumerate(rows):
        if bit_depth == 16:
            row = bytes(line[i] for i in range(0, stride, 2))  # high byte
        else:
            row = bytes(line)
        if color_type == 3:
            if plte is None:
                raise ValueError("palette PNG without PLTE: %s" % path)
            rgb = bytearray()
            for idx in row:
                rgb += plte[idx * 3:idx * 3 + 3]
            row = bytes(rgb)
        out = y * w * 3
        if color_type in (0, 3):
            for x in range(w):
                v = row[x]
                px[out + x * 3] = v; px[out + x * 3 + 1] = v; px[out + x * 3 + 2] = v
        elif color_type == 4:
            for x in range(w):
                v = row[x * 2]
                px[out + x * 3] = v; px[out + x * 3 + 1] = v; px[out + x * 3 + 2] = v
        else:
            px[out:out + w * 3] = row[:w * 3]
    return w, h, 3, bytes(px)

def gray_at(px, w, x, y):
    o = (y * w + x) * 3
    return (px[o] * 299 + px[o + 1] * 587 + px[o + 2] * 114) // 1000
PYEOF
  cat > /tmp/scene_diff.py <<'PYEOF'
import sys, traceback
sys.path.insert(0, "/tmp")
try:
    from pngmini import read_png, gray_at
    w1, h1, _c1, p1 = read_png(sys.argv[1])
    w2, h2, _c2, p2 = read_png(sys.argv[2])
    tot = 0; n = 0
    for gy in range(48):
        y1 = int((gy + 0.5) * (h1 * 0.6) / 48)
        y2 = int((gy + 0.5) * (h2 * 0.6) / 48)
        for gx in range(72):
            x1 = int((gx + 0.5) * w1 / 72)
            x2 = int((gx + 0.5) * w2 / 72)
            tot += abs(gray_at(p1, w1, x1, y1) - gray_at(p2, w2, x2, y2)); n += 1
    diff = tot / n
    print("BIG" if diff > 10 else "SAME")
    print("mean_abs_diff=%.2f" % diff, file=sys.stderr)
except Exception:
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
  # Story-page detector: prints STORY if the bottom strip (y 0.80-0.97h) is a
  # light parchment dialogue box (mean luminance > 170), else OTHER. A normal
  # story page measures ~196-205; decree scroll 26-53; title 33; char-creation 41.
  # STDLIB ONLY (see /tmp/pngmini.py). On ANY error: traceback to stderr and
  # exit 1 — NEVER silently default to STORY (that dead-detector bug stalled
  # runs 43711691091 + 43712648675 mid-story).
  cat > /tmp/story_page.py <<'PYEOF'
import sys, traceback
sys.path.insert(0, "/tmp")
try:
    from pngmini import read_png, gray_at
    w, h, _c, px = read_png(sys.argv[1])
    y0 = int(h * 0.80); y1 = int(h * 0.97)
    tot = 0; n = 0
    for y in range(y0, y1, 2):
        for x in range(0, w, 4):
            tot += gray_at(px, w, x, y); n += 1
    lum = tot / n
    print("STORY" if lum > 170 else "OTHER")
    print("bottom_lum=%.1f" % lum, file=sys.stderr)
except Exception:
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
  echo "== DETECTOR SELF-TEST (known screenshots, before the walk depends on it) =="
  TEST_REIGN=$(python3 /tmp/story_page.py artifacts/screen-reign+30s.png 2>artifacts/detector-test-reign.log || echo DETECTOR_FAIL)
  echo "self-test story detector on screen-reign+30s.png (story page, expect STORY): verdict=$TEST_REIGN $(cat artifacts/detector-test-reign.log)" | tee -a artifacts/launch.log
  TEST_CHAR=$(python3 /tmp/story_page.py artifacts/screen-tap+150s.png 2>artifacts/detector-test-charcreate.log || echo DETECTOR_FAIL)
  echo "self-test story detector on screen-tap+150s.png (char creation, expect OTHER): verdict=$TEST_CHAR $(cat artifacts/detector-test-charcreate.log)" | tee -a artifacts/launch.log
  TEST_DIFF=$(python3 /tmp/scene_diff.py artifacts/screen-60s.png artifacts/screen-tap+150s.png 2>artifacts/detector-test-diff.log || echo DIFF_FAIL)
  echo "self-test scene_diff screen-60s.png vs screen-tap+150s.png (different screens, expect BIG): verdict=$TEST_DIFF $(cat artifacts/detector-test-diff.log)" | tee -a artifacts/launch.log
  if [ "$TEST_REIGN" = "DETECTOR_FAIL" ] || [ "$TEST_CHAR" = "DETECTOR_FAIL" ] || [ "$TEST_DIFF" = "DIFF_FAIL" ]; then
    echo "!!! DETECTOR SELF-TEST FAILED — the pixel detectors do not run on this runner; failing loudly (see artifacts/detector-test-*.log). The walk below will stop at the first detector call." | tee -a artifacts/launch.log
    DETECTOR_FAILED=yes
  fi
  for N in $(seq 1 40); do
    # "Skip" check FIRST: if a Skip button ever appears (uiautomator exposes
    # zero Corona nodes, so this almost certainly never fires), tap it ONCE
    # instead of the "»" button and stop the loop.
    adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_skip.xml 2>&1 | tee -a artifacts/launch.log || true
    adb -s "$DEV" pull /sdcard/window_dump_skip.xml artifacts/uiautomator-story-$N.xml 2>&1 || true
    SKIP_CENTER=$(node_center artifacts/uiautomator-story-$N.xml "skip" 2>/dev/null || true)
    if [ -n "$SKIP_CENTER" ]; then
      SKIP_X=$(echo "$SKIP_CENTER" | cut -d' ' -f1)
      SKIP_Y=$(echo "$SKIP_CENTER" | cut -d' ' -f2)
      echo "story tap $N/20: 'Skip' button found at $SKIP_X,$SKIP_Y — tapping it ONCE instead of '»'" | tee -a artifacts/launch.log
      adb -s "$DEV" shell input tap "$SKIP_X" "$SKIP_Y" 2>&1 || true
      STORY_TAPS=$((STORY_TAPS + 1))
      sleep 15
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-story-$N.png 2>/dev/null || true
      STORY_ENDED=yes
      break
    fi
    echo "story tap $N/40 at $STORY_X,$STORY_Y" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$STORY_X" "$STORY_Y" 2>&1 || true
    STORY_TAPS=$((STORY_TAPS + 1))
    sleep 15
    adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || { echo "app process NOT running after story tap $N — stopping the loop"; break; }
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-story-$N.png 2>/dev/null || true
    ls -la artifacts/screen-story-$N.png 2>&1 || true
    DIFF=$(python3 /tmp/scene_diff.py "$PREV_SHOT" "artifacts/screen-story-$N.png" 2>artifacts/detector-diff-story-$N.log || echo DIFF_FAIL)
    if [ "$DIFF" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-story-$N.png (see artifacts/detector-diff-story-$N.log):"; cat artifacts/detector-diff-story-$N.log; DIFF=SAME; fi
    PAGE=$(python3 /tmp/story_page.py "artifacts/screen-story-$N.png" 2>artifacts/detector-story-$N.log || echo DETECTOR_FAIL)
    if [ "$PAGE" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on screen-story-$N.png — failing loudly, stopping walk 1 (see artifacts/detector-story-$N.log):"; cat artifacts/detector-story-$N.log; DETECTOR_FAILED=yes; break; fi
    echo "detector screen-story-$N.png: $(cat artifacts/detector-story-$N.log 2>/dev/null)" | tee -a artifacts/launch.log
    echo "story tap $N: scene-diff vs previous shot = $DIFF, story-page = $PAGE" | tee -a artifacts/launch.log
    # BIG scene-diff alone NEVER ends the walk (run 43711691091: tap 1 went
    # rainy-city -> forest hunt, a normal story page). End the walk ONLY when
    # the page is no longer a story dialogue page (parchment box gone).
    if [ "$PAGE" = "OTHER" ]; then
      echo "story tap $N: page left the dialogue flow (bottom strip dark) — re-checking after 15 s in case of a fade/transition" | tee -a artifacts/launch.log
      sleep 15
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-story-$N-recheck.png 2>/dev/null || true
      PAGE2=$(python3 /tmp/story_page.py "artifacts/screen-story-$N-recheck.png" 2>artifacts/detector-story-$N-recheck.log || echo DETECTOR_FAIL)
      if [ "$PAGE2" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on recheck screen-story-$N-recheck.png — failing loudly, stopping walk 1:"; cat artifacts/detector-story-$N-recheck.log; DETECTOR_FAILED=yes; break; fi
      echo "story tap $N re-check: story-page = $PAGE2" | tee -a artifacts/launch.log
      if [ "$PAGE2" = "OTHER" ]; then
        echo "confirmed: story dialogue flow left after story tap $N (decree page or home? operator verifies from the pixels)" | tee -a artifacts/launch.log
        STORY_ENDED=yes
        PREV_SHOT="artifacts/screen-story-$N-recheck.png"
        break
      fi
      echo "re-check shows a story page again (was a transition) — resuming the walk" | tee -a artifacts/launch.log
      PREV_SHOT="artifacts/screen-story-$N-recheck.png"
    else
      PREV_SHOT="artifacts/screen-story-$N.png"
    fi
  done
  echo "story walk done: taps=$STORY_TAPS story_ended=$STORY_ENDED" | tee -a artifacts/launch.log
  echo "== DECREE PAGE: screenshot the page the story walk stopped on =="
  sleep 5
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at decree screenshot"
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-decree.png 2>/dev/null || true
  ls -la artifacts/screen-decree.png 2>&1 || true
  DECREE_DIFF=$(python3 /tmp/scene_diff.py "$PREV_SHOT" artifacts/screen-decree.png 2>artifacts/detector-diff-decree.log || echo DIFF_FAIL)
  if [ "$DECREE_DIFF" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-decree.png (see artifacts/detector-diff-decree.log):"; cat artifacts/detector-diff-decree.log; DECREE_DIFF=SAME; fi
  echo "screen-decree.png scene-diff vs last story shot ($PREV_SHOT) = $DECREE_DIFF" | tee -a artifacts/launch.log
  # The center tap is ONLY for the decree-scroll page (detector OTHER, no "»"
  # button). If the walk ended still in dialogue (PAGE STORY), do NOT center-tap
  # a dialogue page — walk 2 resumes the "»" loop instead (see below).
  DECREE_PAGE=$(python3 /tmp/story_page.py artifacts/screen-decree.png 2>artifacts/detector-decree.log || echo DETECTOR_FAIL)
  if [ "$DECREE_PAGE" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on screen-decree.png — failing loudly (see artifacts/detector-decree.log):"; cat artifacts/detector-decree.log; DETECTOR_FAILED=yes; fi
  echo "detector screen-decree.png: $(cat artifacts/detector-decree.log 2>/dev/null) verdict=$DECREE_PAGE" | tee -a artifacts/launch.log
  DECREE_ADVANCED=no
  if [ "$DECREE_PAGE" = "OTHER" ] && [ "$DECREE_DIFF" = "SAME" ]; then
    echo "decree page STABLE (no auto-advance) — tap CENTER SCREEN ONCE at $CX,$CY (360,640 on 720x1280)" | tee -a artifacts/launch.log
    adb -s "$DEV" shell input tap "$CX" "$CY" 2>&1 || true
    echo "decree center tap sent (ONE tap only)" | tee -a artifacts/launch.log
    sleep 30
    adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at decree+30s"
    adb -s "$DEV" exec-out screencap -p > artifacts/screen-decree+30s.png 2>/dev/null || true
    ls -la artifacts/screen-decree+30s.png 2>&1 || true
    DECREE_DIFF2=$(python3 /tmp/scene_diff.py artifacts/screen-decree.png artifacts/screen-decree+30s.png 2>artifacts/detector-diff-decree30.log || echo DIFF_FAIL)
    if [ "$DECREE_DIFF2" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-decree+30s.png:"; cat artifacts/detector-diff-decree30.log; DECREE_DIFF2=SAME; fi
    echo "screen-decree+30s.png scene-diff vs decree page = $DECREE_DIFF2" | tee -a artifacts/launch.log
    if [ "$DECREE_DIFF2" = "BIG" ]; then
      echo "decree page ADVANCED after the center tap" | tee -a artifacts/launch.log
      DECREE_ADVANCED=yes
      PREV_SHOT="artifacts/screen-decree+30s.png"
    else
      echo "still on the decree page after the center tap — waiting a further 60s (it may auto-advance)" | tee -a artifacts/launch.log
      sleep 60
      adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at decree+90s"
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-decree+90s.png 2>/dev/null || true
      ls -la artifacts/screen-decree+90s.png 2>&1 || true
      DECREE_DIFF3=$(python3 /tmp/scene_diff.py artifacts/screen-decree.png artifacts/screen-decree+90s.png 2>artifacts/detector-diff-decree90.log || echo DIFF_FAIL)
      if [ "$DECREE_DIFF3" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-decree+90s.png:"; cat artifacts/detector-diff-decree90.log; DECREE_DIFF3=SAME; fi
      echo "screen-decree+90s.png scene-diff vs decree page = $DECREE_DIFF3" | tee -a artifacts/launch.log
      if [ "$DECREE_DIFF3" = "BIG" ]; then
        echo "decree page ADVANCED during the extra 60s wait" | tee -a artifacts/launch.log
        DECREE_ADVANCED=yes
      else
        echo "decree page NEVER advanced (center tap + 60s wait) — stopping here, no further blind taps" | tee -a artifacts/launch.log
      fi
      PREV_SHOT="artifacts/screen-decree+90s.png"
    fi
  else
    echo "no decree center tap: page is '$DECREE_PAGE' (detector) / scene-diff $DECREE_DIFF — center tap is only for a stable decree-scroll page; if still in dialogue, walk 2 resumes the '»' loop" | tee -a artifacts/launch.log
    PREV_SHOT="artifacts/screen-decree.png"
  fi
  echo "decree_advanced=$DECREE_ADVANCED" | tee -a artifacts/launch.log
  echo "== STORY WALK 2 (RESUME): runs WHENEVER walk 1 ends still in dialogue — NOT only when decree_advanced=yes =="
  STORY2_TAPS=0
  STORY2_ENDED=no
  STORY2_BIG=no
  # Fresh detector verdict on the CURRENT page decides: STORY (dialogue with a
  # "»" button) -> resume the loop; OTHER (decree/home/other) -> no walk 2.
  # This covers both cases: walk 1 ran out of its 40 taps mid-story, and the
  # decree center-tap advanced to another story page (Piyale...).
  sleep 5
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-resume-check.png 2>/dev/null || true
  RESUME_PAGE=$(python3 /tmp/story_page.py artifacts/screen-resume-check.png 2>artifacts/detector-resume-check.log || echo DETECTOR_FAIL)
  if [ "$RESUME_PAGE" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on screen-resume-check.png — failing loudly (see artifacts/detector-resume-check.log):"; cat artifacts/detector-resume-check.log; DETECTOR_FAILED=yes; fi
  echo "detector screen-resume-check.png: $(cat artifacts/detector-resume-check.log 2>/dev/null) verdict=$RESUME_PAGE (walk1 taps=$STORY_TAPS story_ended=$STORY_ENDED decree_advanced=$DECREE_ADVANCED)" | tee -a artifacts/launch.log
  PREV_SHOT="artifacts/screen-resume-check.png"
  if [ "$RESUME_PAGE" = "STORY" ]; then
    for N in $(seq 1 20); do
      adb -s "$DEV" shell uiautomator dump /sdcard/window_dump_skip2.xml 2>&1 | tee -a artifacts/launch.log || true
      adb -s "$DEV" pull /sdcard/window_dump_skip2.xml artifacts/uiautomator-story2-$N.xml 2>&1 || true
      SKIP2_CENTER=$(node_center artifacts/uiautomator-story2-$N.xml "skip" 2>/dev/null || true)
      if [ -n "$SKIP2_CENTER" ]; then
        SKIP2_X=$(echo "$SKIP2_CENTER" | cut -d' ' -f1)
        SKIP2_Y=$(echo "$SKIP2_CENTER" | cut -d' ' -f2)
        echo "story2 tap $N/20: 'Skip' button found at $SKIP2_X,$SKIP2_Y — tapping it ONCE instead of '»'" | tee -a artifacts/launch.log
        adb -s "$DEV" shell input tap "$SKIP2_X" "$SKIP2_Y" 2>&1 || true
        STORY2_TAPS=$((STORY2_TAPS + 1))
        sleep 15
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-story2-$N.png 2>/dev/null || true
        STORY2_ENDED=yes
        STORY2_BIG=yes
        PREV_SHOT="artifacts/screen-story2-$N.png"
        break
      fi
      echo "story2 tap $N/20 at $STORY_X,$STORY_Y" | tee -a artifacts/launch.log
      adb -s "$DEV" shell input tap "$STORY_X" "$STORY_Y" 2>&1 || true
      STORY2_TAPS=$((STORY2_TAPS + 1))
      sleep 15
      adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || { echo "app process NOT running after story2 tap $N — stopping the loop"; break; }
      adb -s "$DEV" exec-out screencap -p > artifacts/screen-story2-$N.png 2>/dev/null || true
      ls -la artifacts/screen-story2-$N.png 2>&1 || true
      DIFF2=$(python3 /tmp/scene_diff.py "$PREV_SHOT" "artifacts/screen-story2-$N.png" 2>artifacts/detector-diff-story2-$N.log || echo DIFF_FAIL)
      if [ "$DIFF2" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-story2-$N.png:"; cat artifacts/detector-diff-story2-$N.log; DIFF2=SAME; fi
      PAGE=$(python3 /tmp/story_page.py "artifacts/screen-story2-$N.png" 2>artifacts/detector-story2-$N.log || echo DETECTOR_FAIL)
      if [ "$PAGE" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on screen-story2-$N.png — failing loudly, stopping walk 2:"; cat artifacts/detector-story2-$N.log; DETECTOR_FAILED=yes; break; fi
      echo "detector screen-story2-$N.png: $(cat artifacts/detector-story2-$N.log 2>/dev/null)" | tee -a artifacts/launch.log
      echo "story2 tap $N: scene-diff vs previous shot = $DIFF2, story-page = $PAGE" | tee -a artifacts/launch.log
      # BIG scene-diff alone NEVER ends the walk (see walk 1). End ONLY when
      # the page is no longer a story dialogue page.
      if [ "$PAGE" = "OTHER" ]; then
        echo "story2 tap $N: page left the dialogue flow — re-checking after 15 s in case of a fade/transition" | tee -a artifacts/launch.log
        sleep 15
        adb -s "$DEV" exec-out screencap -p > artifacts/screen-story2-$N-recheck.png 2>/dev/null || true
        PAGE2=$(python3 /tmp/story_page.py "artifacts/screen-story2-$N-recheck.png" 2>artifacts/detector-story2-$N-recheck.log || echo DETECTOR_FAIL)
        if [ "$PAGE2" = "DETECTOR_FAIL" ]; then echo "!!! STORY DETECTOR FAILED on recheck screen-story2-$N-recheck.png — failing loudly, stopping walk 2:"; cat artifacts/detector-story2-$N-recheck.log; DETECTOR_FAILED=yes; break; fi
        echo "story2 tap $N re-check: story-page = $PAGE2" | tee -a artifacts/launch.log
        if [ "$PAGE2" = "OTHER" ]; then
          echo "confirmed: story dialogue flow left after story2 tap $N (home? operator verifies from the pixels)" | tee -a artifacts/launch.log
          STORY2_ENDED=yes
          STORY2_BIG=yes
          PREV_SHOT="artifacts/screen-story2-$N-recheck.png"
          break
        fi
        echo "re-check shows a story page again (was a transition) — resuming walk 2" | tee -a artifacts/launch.log
        PREV_SHOT="artifacts/screen-story2-$N-recheck.png"
      else
        PREV_SHOT="artifacts/screen-story2-$N.png"
      fi
    done
  else
    echo "current page is NOT story dialogue (detector verdict '$RESUME_PAGE') — no story walk 2 (do not keep tapping blindly)" | tee -a artifacts/launch.log
  fi
  echo "story walk 2 done: taps=$STORY2_TAPS story2_ended=$STORY2_ENDED story2_big=$STORY2_BIG (STORY2_BIG=yes means the page left the story dialogue flow, confirmed by re-check)" | tee -a artifacts/launch.log
  echo "== final screenshots (screen-home.png) =="
  sleep 5
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running at final screenshot"
  adb -s "$DEV" shell dumpsys window windows 2>/dev/null | grep -i "mCurrentFocus" | head -3 || true
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-home.png 2>/dev/null || true
  ls -la artifacts/screen-home.png 2>&1 || true
  HOME_DIFF=$(python3 /tmp/scene_diff.py "$PREV_SHOT" artifacts/screen-home.png 2>artifacts/detector-diff-home.log || echo DIFF_FAIL)
  if [ "$HOME_DIFF" = "DIFF_FAIL" ]; then echo "scene_diff FAILED on screen-home.png:"; cat artifacts/detector-diff-home.log; HOME_DIFF=SAME; fi
  echo "screen-home.png scene-diff vs last decree/story shot ($PREV_SHOT) = $HOME_DIFF" | tee -a artifacts/launch.log
  # home_reached must NOT follow from STORY_ENDED or DECREE_ADVANCED alone
  # (runs 43709009089 + 43710283715 false positives — a new story page is not
  # home; "left the decree page" is not "reached home"). It follows ONLY from
  # a big scene change AFTER the resumed story walk (STORY2_BIG) or a big
  # change of the final screenshot vs the last story shot — i.e. the screen
  # visibly left the story. The operator verifies from screen-home.png pixels.
  if [ "${STORY2_BIG:-no}" = "yes" ] || [ "$HOME_DIFF" = "BIG" ]; then
    HOME_REACHED=yes
  fi
  echo "home_reached (heuristic: big scene change after resumed story walk, or final shot differs substantially vs last story shot; verify visually from screen-home.png): $HOME_REACHED" | tee -a artifacts/launch.log
  # ROUND 2 — VIP scene / caps / relaunch (REPLACES the old profile tap:
  # the (70,90) avatar tap opened the CHALLENGE LETTER, not the profile —
  # see work/redroid-r2/ui-recon.md. The letter intercepts the FIRST tap
  # anywhere on home, so it must be dismissed + verified gone first.)
  # NEVER tap any purchase/claim/buy button in the dialog or the VIP tab.
  LETTER_DISMISSED=no
  VIP_TAB_REACHED=no
  PRIVILEGE_OPENED=no
  RELAUNCH_HOME=no
  RELAUNCH_VIP16=unknown
  PROFILE_TAPPED=no
  # DYNREA SOAK (replaces round 2): NO VIP/Commerce/relaunch taps in the
  # baseline run. Hold at home with Frida still attached to capture
  # home/idle/periodic gateway traffic, then screenshot. Sibling probe
  # agents add their own post-home taps in their own runs (READY.md).
  LETTER_DISMISSED=not-applicable
  VIP_TAB_REACHED=not-applicable
  PRIVILEGE_OPENED=not-applicable
  RELAUNCH_HOME=not-applicable
  RELAUNCH_VIP16=not-applicable
  PROFILE_TAPPED=not-applicable
  SOAK_SECONDS=${SOAK_SECONDS:-90}
  echo "== DYNREA SOAK: home_reached=$HOME_REACHED — holding $SOAK_SECONDS s with Frida attached to capture home/idle traffic ==" | tee -a artifacts/launch.log
  sleep "$SOAK_SECONDS"
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after soak"
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-soak.png 2>/dev/null || true
  ls -la artifacts/screen-soak.png 2>&1 || true
  if grep -q "ALL PRIMARY HOOKS ATTACHED" artifacts/frida.log 2>/dev/null; then
    FRIDA_ATTACHED=yes
    echo "FRIDA re-check at soak: hooks confirmed attached" | tee -a artifacts/launch.log
  else
    echo "FRIDA re-check at soak: hooks NOT confirmed — see artifacts/frida.log" | tee -a artifacts/launch.log
  fi
  echo "soak done (home_reached=$HOME_REACHED frida_attached=$FRIDA_ATTACHED)" | tee -a artifacts/launch.log
fi

echo "== FRIDA STOP (before logcat — detach so frida.log is complete) =="
stop_frida || true

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

echo "== FRIDA STATS (from artifacts/frida.log) =="
FRIDA_LINES=0; FRIDA_ACTIONS=0; FRIDA_ACTION_IDS=""; FRIDA_FLIP_OUT=0; FRIDA_FLIP_IN=0
if [ -s artifacts/frida.log ]; then
  FRIDA_LINES=$(wc -l < artifacts/frida.log)
  FRIDA_ACTIONS=$(grep -c "ACTION\] id=" artifacts/frida.log || true)
  FRIDA_ACTION_IDS=$(grep -o "ACTION\] id=[0-9]*" artifacts/frida.log | grep -o "[0-9]*" | sort -un | tr '\n' ',' | sed 's/,$//' || true)
  FRIDA_FLIP_OUT=$(grep -c "flip\] REQ-PLAIN" artifacts/frida.log || true)
  FRIDA_FLIP_IN=$(grep -c "flip\] RESP-PLAIN" artifacts/frida.log || true)
  if grep -q "ALL PRIMARY HOOKS ATTACHED" artifacts/frida.log; then FRIDA_ATTACHED=yes; fi
fi
echo "frida_attached=$FRIDA_ATTACHED lines=$FRIDA_LINES actions=$FRIDA_ACTIONS flip_out=$FRIDA_FLIP_OUT flip_in=$FRIDA_FLIP_IN ids=${FRIDA_ACTION_IDS:-none}"

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
echo "story_taps: ${STORY_TAPS:-0} story_ended: ${STORY_ENDED:-no} decree_advanced: ${DECREE_ADVANCED:-no} story2_taps: ${STORY2_TAPS:-0} story2_ended: ${STORY2_ENDED:-no} story2_big: ${STORY2_BIG:-no} home_reached: ${HOME_REACHED:-no} detector_failed: ${DETECTOR_FAILED:-no}"
echo "profile_tapped: ${PROFILE_TAPPED:-no}"

{
  echo "RESULT: install_ok=$INSTALL_OK logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no) native_lib_error=$([ -s artifacts/native-lib-lines.txt ] && echo yes || echo no) subpack_error=$([ -s artifacts/subpack-lines.txt ] && echo yes || echo no) login_reached=$LOGIN_REACHED reign_reached=$REIGN_REACHED story_taps=${STORY_TAPS:-0} story_ended=${STORY_ENDED:-no} decree_advanced=${DECREE_ADVANCED:-no} story2_taps=${STORY2_TAPS:-0} story2_ended=${STORY2_ENDED:-no} story2_big=${STORY2_BIG:-no} home_reached=${HOME_REACHED:-no} profile_tapped=${PROFILE_TAPPED:-no} detector_failed=${DETECTOR_FAILED:-no} letter_dismissed=${LETTER_DISMISSED:-no} vip_tab_reached=${VIP_TAB_REACHED:-no} privilege_opened=${PRIVILEGE_OPENED:-no} relaunch_home=${RELAUNCH_HOME:-no} relaunch_vip16=unknown vip_visible=unknown consent_dismissed=${CONSENT_DISMISSED:-not-present}"
  echo "login_reached is a heuristic (screen-home.png differs from screen-60s.png); confirm from the screenshots"
  echo "reign_reached is a heuristic (screen-reign+30s.png differs from screen-tap+150s.png); confirm from the screenshots"
  echo "home_reached is a heuristic (big scene change after the RESUMED story walk, or screen-home.png differs substantially from the last story shot); decree_advanced alone NEVER implies home; confirm from screen-home.png"
  echo "decree_advanced=yes means the decree-scroll page left the screen after the single center tap (screen-decree+30s.png) or during the extra 60s wait (screen-decree+90s.png); confirm from those screenshots"
  echo "overlay dismiss: screen-overlay-dismiss.png shows the state after the GOT IT tap (banner should be GONE); screen-overlay-dismiss-2.png exists only if a second tap was needed"
  echo "consent_dismissed=yes means the 'Personalized Advertisement Statement' dialog was found and dismissed (screen-consent-dismiss.png / -tap / -relaunch show the state after the dismiss); not-present means no dialog appeared; no means it was still present after two taps"
  echo "story_taps counts '»' advance taps in walk 1 (up to 40) (+1 if a Skip button was tapped instead on the final iteration); story2_taps counts '»' taps in the resumed walk past the decree (screen-story2-N.png, up to 20) — walk 2 runs whenever walk 1 ends still in dialogue, not only when decree_advanced=yes"
  echo "detector_failed=yes means the stdlib pixel detector errored on the runner (see artifacts/detector-*.log) — the walk stopped at the first failed detector call instead of silently defaulting to STORY"
  echo "vip_visible=unknown: the script cannot read pixels — the operator determines VIP from screen-home.png and screen-profile.png (look for a VIP level/badge, e.g. 'VIP 16', on the home/profile screen)"
  echo "round2: NOT RUN in the dynrea baseline (soak replaces it — see frida_* fields above); letter/vip_tab/privilege/relaunch are not-applicable here, sibling probe runs cover post-home taps"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK (MOD VIP16+arm64 libs, sha256 $APK_SHA256) + $PAD1 (re-signed PAD1 split, sha256 $PAD1_SHA256) via install-multiple"
} | tee artifacts/RESULT.md

{
  echo "frida_attached=$FRIDA_ATTACHED frida_log_lines=${FRIDA_LINES:-0} frida_actions=${FRIDA_ACTIONS:-0} frida_action_ids=${FRIDA_ACTION_IDS:-none} frida_flip_out=${FRIDA_FLIP_OUT:-0} frida_flip_in=${FRIDA_FLIP_IN:-0} frida_script=$FRIDA_SCRIPT"
  echo "frida_attached=yes means artifacts/frida.log contains 'ALL PRIMARY HOOKS ATTACHED'; frida_actions counts [DYNREA][ACTION] lines (plaintext action ids seen through KSecure flip); verify from frida.log, not from this line alone"
  echo "frida hook points: KSecureValidation.flip(KSNetMeta) dir=1 OUT plaintext request / dir=0 IN plaintext response; flip2([B)[B; KSInterceptor.intercept metadata; KSecureValidation.init/enable lifecycle"
} | tee -a artifacts/RESULT.md

docker rm -f redroid >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$LOG_OK" = "1" ]; then
  echo "DONE: install + logcat captured"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK logcat_ok=$LOG_OK"
exit 1
