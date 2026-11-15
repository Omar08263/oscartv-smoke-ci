#!/usr/bin/env bash
# Kolnovel MITM test on Redroid (arm64 Android userspace, NO KVM).
# Vector (c) of the locked-chapter live verdict (round 3, 2026-11-15).
#
# Question: does the app's client trust the server's /reader access
# object (is_locked / has_access) at runtime? The live server returns
# has_access=true for every chapter tested (157 probes, 0 locked), so
# there is NO locked response to flip open. This run flips the other
# way: mitmproxy rewrites a /reader response's access object from
# has_access=true / is_locked=false to has_access=false /
# is_locked=true and blanks the content. If the app then shows the
# lock screen, the client is proven to obey the server's flag at
# runtime (lock is server-driven). If it still renders the chapter,
# the client ignores the flag.
#
# Setup: mitmproxy runs in Docker on the runner; Redroid (also Docker)
# is pointed at it via the Android global http_proxy; the mitmproxy CA
# is installed into Redroid's SYSTEM trust store (adb root + remount)
# because the app (release build, no cert pinning) trusts system CAs
# only. Redroid is rebooted after the CA install so the store reloads.
#
# App: com.benabdellah.KolNovelApp v83/5.2.5, v3 mod
# (sha256 4488b494194f12200229f3364fdc226a51f355f9ae49a4e41a7b1d8d36112592).
# Navigation is best-effort (uiautomator text taps): consent -> skip
# onboarding -> Discover tab -> first novel -> first chapter. Every
# step screenshots + dumps UI; the SUCCESS criterion is the mitmproxy
# log showing a /reader request (proving the app reached the reader).
set -u
mkdir -p artifacts mitm
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v3.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
INSTALL_OK=0
LOG_OK=0
MITM_OK=0
READER_SEEN=0

# --- tap helpers (from kolnovel-redroid-panel.sh) ---
cat > /tmp/tap.py <<'PYEOF'
import sys, re
import xml.etree.ElementTree as ET
xml, texts = sys.argv[1], sys.argv[2:]
try:
    root = ET.parse(xml).getroot()
except Exception as e:
    print(f"XML parse fail: {e}", file=sys.stderr); sys.exit(1)
best = None
for node in root.iter('node'):
    t = (node.get('text') or '') + '|' + (node.get('content-desc') or '')
    if not any(x in t for x in texts):
        continue
    b = node.get('bounds') or ''
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    clickable = node.get('clickable') == 'true'
    cand = ((0 if clickable else 1), (x2 - x1) * (y2 - y1), (x1 + x2) // 2, (y1 + y2) // 2)
    if best is None or cand[:2] < best[:2]:
        best = cand
if best is None:
    sys.exit(1)
print(f"{best[2]} {best[3]}")
PYEOF
dump_ui() { # $1 = out name
  local i
  for i in 1 2 3; do
    adb -s "$DEV" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb -s "$DEV" pull /sdcard/ui.xml "artifacts/$1" >/dev/null 2>&1
    if [ -s "artifacts/$1" ] && grep -q "<hierarchy" "artifacts/$1" 2>/dev/null; then
      echo "ui dump $1 OK (try $i)"
      return 0
    fi
    echo "ui dump $1 empty/bad, retry $i"
    sleep 3
  done
  echo "ui dump $1 FAILED after retries"
  ls -la "artifacts/$1" 2>&1 || true
}
tap_text() { # $1 = xml file, $2.. = texts to try
  local xml="$1"; shift
  local xy
  xy=$(python3 /tmp/tap.py "artifacts/$xml" "$@" 2>/dev/null) || return 1
  echo "tap $xy for text [$*] in $xml"
  adb -s "$DEV" shell input tap $xy
}
shoot() { # $1 = out name
  adb -s "$DEV" exec-out screencap -p > "artifacts/$1" 2>/dev/null || echo "screencap $1 FAILED"
  ls -la "artifacts/$1" 2>&1 || true
}
wait_boot() { # up to 600s; sets BOOT_OK
  BOOT_OK=0
  for i in $(seq 1 60); do
    adb connect "$DEV" >/dev/null 2>&1 || true
    if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
      BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
    fi
    sleep 10
  done
}

echo "== host =="
uname -m
nproc; free -h | head -2
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb openssl || echo "apt install FAILED"
fi
adb --version | head -1 || echo "adb STILL MISSING"
openssl version || echo "NO OPENSSL"

echo "== kernel modules (binder/ashmem) =="
ls /dev/binder* /dev/ashmem 2>&1 || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder_linux modprobe FAILED (may be built-in or absent)"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem_linux modprobe FAILED (may be built-in or absent)"
ls -l /dev/binder* /dev/ashmem 2>&1 || echo "NO binder/ashmem devices after modprobe"

echo "== start mitmproxy (docker, addon flips /reader access true->false) =="
docker pull mitmproxy/mitmproxy:11 2>&1 | tail -3
docker rm -f mitm >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name mitm -p 8080:8080 \
  -v "$PWD/scripts/kolnovel-mitm-addon.py:/addon.py:ro" \
  -v "$PWD/mitm:/mitm" \
  -e MITM_LOG=/mitm/mitm-log.jsonl \
  mitmproxy/mitmproxy:11 mitmdump -s /addon.py --set block_global=false 2>&1
sleep 8
docker ps --filter name=mitm --format '{{.Status}} {{.Image}}' 2>&1
docker logs mitm 2>&1 | tail -15 || true
# Wait for the CA to be generated, then extract it.
for i in $(seq 1 10); do
  if docker exec mitm test -f /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem 2>/dev/null; then
    echo "mitmproxy CA present after ~$((i * 3))s"; break
  fi
  sleep 3
done
docker cp mitm:/home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem mitm/mitmproxy-ca-cert.pem 2>&1 || echo "CA COPY FAILED"
ls -la mitm/ 2>&1
if [ -f mitm/mitmproxy-ca-cert.pem ]; then
  CA_HASH=$(openssl x509 -inform PEM -subject_hash_old -noout -in mitm/mitmproxy-ca-cert.pem 2>/dev/null)
  echo "CA subject_hash_old: $CA_HASH"
  if [ -n "$CA_HASH" ]; then
    cp mitm/mitmproxy-ca-cert.pem "mitm/${CA_HASH}.0"
    echo "CA stored as mitm/${CA_HASH}.0"
    MITM_OK=1
  fi
fi
GATEWAY=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
echo "docker bridge gateway (proxy address from Redroid): $GATEWAY"
[ -z "$GATEWAY" ] && GATEWAY="172.17.0.1" && echo "gateway fallback to $GATEWAY"

echo "== pull Redroid arm64 image =="
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -5

echo "== start Redroid (first boot, for CA install) =="
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
echo "device mounts:$MOUNTS"
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
wait_boot
if [ "$BOOT_OK" != "1" ]; then
  echo "REDROID DID NOT BOOT in 600s (first boot)"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  echo "RESULT: REDROID_BOOT_FAILED" > artifacts/RESULT.md
  exit 1
fi
adb -s "$DEV" shell getprop ro.product.cpu.abi
adb -s "$DEV" shell getprop ro.build.version.release

echo "== install mitmproxy CA into system trust store =="
CA_INSTALLED=0
if [ "$MITM_OK" = "1" ] && [ -n "${CA_HASH:-}" ]; then
  adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
  sleep 3
  adb connect "$DEV" >/dev/null 2>&1 || true
  adb -s "$DEV" remount 2>&1 || adb -s "$DEV" shell mount -o remount,rw /system 2>&1 || echo "remount FAILED (trying push anyway)"
  adb -s "$DEV" push "mitm/${CA_HASH}.0" "/sdcard/${CA_HASH}.0" 2>&1
  adb -s "$DEV" shell "cp /sdcard/${CA_HASH}.0 /system/etc/security/cacerts/${CA_HASH}.0 && chmod 644 /system/etc/security/cacerts/${CA_HASH}.0 && ls -la /system/etc/security/cacerts/${CA_HASH}.0" 2>&1
  if adb -s "$DEV" shell "ls /system/etc/security/cacerts/${CA_HASH}.0" 2>/dev/null | grep -q "${CA_HASH}.0"; then
    echo "CA INSTALLED in system store"
    CA_INSTALLED=1
  else
    echo "CA INSTALL FAILED"
  fi
else
  echo "SKIPPING CA install (mitmproxy CA unavailable)"
fi

echo "== reboot Redroid so the CA store reloads =="
docker restart redroid 2>&1
sleep 5
wait_boot
if [ "$BOOT_OK" != "1" ]; then
  echo "REDROID DID NOT BOOT after CA-install reboot"
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  echo "RESULT: REDROID_REBOOT_FAILED" > artifacts/RESULT.md
  exit 1
fi

echo "== set global HTTP proxy to mitmproxy =="
adb -s "$DEV" shell settings put global http_proxy "${GATEWAY}:8080" 2>&1
adb -s "$DEV" shell settings get global http_proxy 2>&1
# sanity: the proxy answers (from the runner, the port is published)
curl -s -o /dev/null -w "mitmproxy port from runner: %{http_code}\n" --max-time 10 "http://localhost:8080/" || echo "proxy port check done (non-200 expected for plain HTTP)"

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

if [ "$INSTALL_OK" = "1" ]; then
  echo "== launch MainActivity =="
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
  sleep 60
  adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after 60s"
  shoot screen-60s.png
fi

echo "== navigate to a chapter (best-effort): consent -> skip -> Discover -> novel -> chapter =="
dismiss_consent() { # $1 = dump file
  if grep -qi "Consent" "artifacts/$1" 2>/dev/null; then
    echo "UMP consent dialog detected in $1, tapping Consent"
    tap_text "$1" "Consent" || adb -s "$DEV" shell input tap 360 955
    sleep 5
    return 0
  fi
  return 1
}
dump_ui ui1.xml
if dismiss_consent ui1.xml; then shoot screen-after-consent.png; dump_ui ui1b.xml; dismiss_consent ui1b.xml || true; fi
dump_ui ui2.xml
dismiss_consent ui2.xml && { shoot screen-after-consent.png; dump_ui ui2b.xml; cp artifacts/ui2b.xml artifacts/ui2.xml; }
tap_text ui2.xml "تخطي" || { echo "skip text not found, fallback tap 635 125"; adb -s "$DEV" shell input tap 635 125; }
sleep 8
shoot screen-after-skip.png
dump_ui ui3.xml
dismiss_consent ui3.xml && { dump_ui ui3b.xml; cp artifacts/ui3b.xml artifacts/ui3.xml; }
if grep -q "تخطي" artifacts/ui3.xml; then
  echo "onboarding still present, retrying skip"
  tap_text ui3.xml "تخطي" || adb -s "$DEV" shell input tap 635 125
  sleep 8
  shoot screen-after-skip2.png
  dump_ui ui3b.xml
  cp artifacts/ui3b.xml artifacts/ui3.xml
fi
# Home -> Discover tab (اكتشف).
if grep -q "اكتشف" artifacts/ui3.xml; then
  tap_text ui3.xml "اكتشف" || echo "discover tab tap failed"
  sleep 10
  shoot screen-discover.png
  dump_ui ui4.xml
  dismiss_consent ui4.xml && { dump_ui ui4b.xml; cp artifacts/ui4b.xml artifacts/ui4.xml; }
else
  echo "NOT ON HOME SCREEN after skip (ui3 has no tab bar) — aborting nav"
  cp artifacts/ui3.xml artifacts/ui4.xml
fi
# Discover -> first novel: tap the first large card. Novel titles are
# Arabic; try tapping a text node that looks like a title by tapping the
# biggest clickable in the upper half via tap.py on a generic probe is
# not supported, so fall back to tapping the first novel cover area.
# Strategy: tap the centre of the first row (y~450) where novel cards sit.
if grep -q "اكتشف" artifacts/ui4.xml || grep -qi "رواية\|روايات" artifacts/ui4.xml; then
  echo "on Discover, tapping first novel card (centre, y~450)"
  adb -s "$DEV" shell input tap 360 450
  sleep 10
  shoot screen-novel.png
  dump_ui ui5.xml
  dismiss_consent ui5.xml && { dump_ui ui5b.xml; cp artifacts/ui5b.xml artifacts/ui5.xml; }
else
  echo "NOT ON DISCOVER (ui4) — aborting nav"
  cp artifacts/ui4.xml artifacts/ui5.xml
fi
# Novel detail -> first chapter: chapter rows usually show the chapter
# title/number; try common texts, else tap the first row (y~450).
if grep -qi "فصل\|الفصول\|chapter" artifacts/ui5.xml; then
  tap_text ui5.xml "الفصل 1" "1" || { echo "chapter text tap failed, tapping first row y~450"; adb -s "$DEV" shell input tap 360 450; }
  sleep 10
  shoot screen-reader.png
  dump_ui ui6.xml
else
  echo "NO chapter list visible in ui5 — trying a row tap anyway"
  adb -s "$DEV" shell input tap 360 450
  sleep 10
  shoot screen-reader.png
  dump_ui ui6.xml
fi
adb -s "$DEV" shell pidof "$PKG" 2>&1 | tee -a artifacts/launch.log || echo "app process NOT running after navigation"

echo "== capture logcat + mitm log =="
adb -s "$DEV" logcat -d > artifacts/logcat.txt 2>&1 || echo "logcat -d FAILED"
adb -s "$DEV" logcat -d -b crash > artifacts/logcat-crash.txt 2>&1 || true
docker logs mitm > artifacts/mitm-docker.log 2>&1 || true
cp mitm/mitm-log.jsonl artifacts/mitm-log.jsonl 2>/dev/null || echo "mitm log copy FAILED (no flows?)"
ls -la mitm/ artifacts/mitm-log.jsonl 2>&1 || true
if [ -s artifacts/mitm-log.jsonl ]; then LOG_OK=1; fi
if grep -q "/reader/" artifacts/mitm-log.jsonl 2>/dev/null; then READER_SEEN=1; echo "MITM: /reader request OBSERVED"; fi
grep -c "kolnovel.com" artifacts/mitm-log.jsonl 2>/dev/null || echo "0 kolnovel flows logged"
grep "flipped" artifacts/mitm-log.jsonl 2>/dev/null | head -5 || echo "no flipped /reader response logged"
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
wc -l artifacts/logcat.txt 2>&1 || true

echo "== FATAL scan =="
grep -i -B2 -A40 "FATAL EXCEPTION" artifacts/logcat.txt > artifacts/fatal.txt 2>/dev/null || true
if [ -s artifacts/fatal.txt ]; then
  echo "FATAL EXCEPTION FOUND:"
  cat artifacts/fatal.txt
else
  echo "no FATAL EXCEPTION in logcat"
fi

{
  echo "RESULT: install_ok=$INSTALL_OK mitm_ok=$MITM_OK ca_installed=$CA_INSTALLED reader_seen=$READER_SEEN logcat_ok=$LOG_OK fatal_found=$([ -s artifacts/fatal.txt ] && echo yes || echo no)"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
  echo "proxy: ${GATEWAY}:8080"
} | tee artifacts/RESULT.md

docker rm -f redroid mitm >/dev/null 2>&1 || true

if [ "$INSTALL_OK" = "1" ] && [ "$READER_SEEN" = "1" ]; then
  echo "DONE: install + /reader observed through MITM"
  exit 0
fi
echo "DONE WITH FAILURES: install_ok=$INSTALL_OK reader_seen=$READER_SEEN mitm_ok=$MITM_OK ca_installed=$CA_INSTALLED"
exit 1
