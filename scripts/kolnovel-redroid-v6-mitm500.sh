#!/usr/bin/env bash
# Kolnovel v6 - Server-500 failure-path test on Redroid (arm64) — problem 2, Case C.
# A mitmproxy addon returns a REAL HTTP 500 for /reader/* after the 3rd
# request, so the export starts, fetches a few chapters, then hits 500s
# mid-fetch. /titles/* and /reading-list/* pass through untouched.
# Expected (clean failure): error toast, NO print job, NO PDF, NO crash,
# PdfExportActivity finishes. The mitm log is the proof the 500s fired.
# Setup reuses kolnovel-redroid-mitm.sh: mitmproxy in Docker, device global
# http_proxy, CA installed into the system trust store + reboot.
set -u
mkdir -p artifacts mitm
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v5.apk"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
PDF_ACT="com.benabdellah.KolNovelApp/.PdfExportActivity"
DEV="localhost:5555"
INSTALL_OK=0
MITM_OK=0
INJECTED=0

wait_boot() {
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
docker --version || echo "NO DOCKER"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB - installing"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb openssl || echo "apt install FAILED"
fi
openssl version || echo "NO OPENSSL"
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"

echo "== start mitmproxy (docker, 500-injection addon) =="
docker pull mitmproxy/mitmproxy:11 2>&1 | tail -3
docker rm -f mitm >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name mitm -p 8080:8080 \
  -v "$PWD/scripts/kolnovel-mitm-500-addon.py:/addon.py:ro" \
  -e MITM_LOG=/tmp/mitm-log.jsonl -e MITM_500_AFTER=3 \
  mitmproxy/mitmproxy:11 mitmdump -s /addon.py --set block_global=false 2>&1
sleep 8
docker ps --filter name=mitm --format '{{.Status}} {{.Image}}' 2>&1
docker logs mitm 2>&1 | tail -10 || true
for i in $(seq 1 10); do
  if docker exec mitm test -f /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem 2>/dev/null; then
    echo "mitmproxy CA present after ~$((i * 3))s"; break
  fi
  sleep 3
done
docker cp mitm:/home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem mitm/mitmproxy-ca-cert.pem 2>&1 || echo "CA COPY FAILED"
if [ -f mitm/mitmproxy-ca-cert.pem ]; then
  CA_HASH=$(openssl x509 -inform PEM -subject_hash_old -noout -in mitm/mitmproxy-ca-cert.pem 2>/dev/null)
  echo "CA subject_hash_old: $CA_HASH"
  if [ -n "$CA_HASH" ]; then
    cp mitm/mitmproxy-ca-cert.pem "mitm/${CA_HASH}.0"
    MITM_OK=1
  fi
fi
GATEWAY=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
[ -z "$GATEWAY" ] && GATEWAY="172.17.0.1" && echo "gateway fallback to $GATEWAY"
echo "docker bridge gateway: $GATEWAY"

echo "== pull Redroid arm64 image =="
docker pull redroid/redroid:13.0.0-latest 2>&1 | tail -3
MOUNTS=""
for d in binder hwbinder vndbinder ashmem; do
  if [ -e "/dev/$d" ]; then MOUNTS="$MOUNTS -v /dev/$d:/dev/$d"; fi
done
# shellcheck disable=SC2086
docker run -d --privileged --name redroid $MOUNTS -p 5555:5555 \
  redroid/redroid:13.0.0-latest androidboot.redroid_gpu_mode=guest 2>&1
sleep 5
wait_boot
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > artifacts/RESULT.md; exit 1; fi

echo "== install mitmproxy CA into system trust store =="
CA_INSTALLED=0
if [ "$MITM_OK" = "1" ] && [ -n "${CA_HASH:-}" ]; then
  adb -s "$DEV" root 2>&1 || echo "adb root FAILED"
  sleep 3
  adb connect "$DEV" >/dev/null 2>&1 || true
  adb -s "$DEV" remount 2>&1 || adb -s "$DEV" shell mount -o remount,rw /system 2>&1 || echo "remount FAILED"
  adb -s "$DEV" push "mitm/${CA_HASH}.0" "/sdcard/${CA_HASH}.0" 2>&1
  adb -s "$DEV" shell "cp /sdcard/${CA_HASH}.0 /system/etc/security/cacerts/${CA_HASH}.0 && chmod 644 /system/etc/security/cacerts/${CA_HASH}.0 && ls -la /system/etc/security/cacerts/${CA_HASH}.0" 2>&1
  if adb -s "$DEV" shell "ls /system/etc/security/cacerts/${CA_HASH}.0" 2>/dev/null | grep -q "${CA_HASH}.0"; then
    echo "CA INSTALLED in system store"; CA_INSTALLED=1
  else echo "CA INSTALL FAILED"; fi
else echo "SKIPPING CA install"; fi

echo "== reboot Redroid so the CA store reloads =="
docker restart redroid 2>&1
sleep 5
wait_boot
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_REBOOT_FAILED" > artifacts/RESULT.md; exit 1; fi

echo "== set global HTTP proxy to mitmproxy =="
adb -s "$DEV" shell settings put global http_proxy "${GATEWAY}:8080" 2>&1
adb -s "$DEV" shell settings get global http_proxy 2>&1

echo "== install APK =="
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
if grep -q "Success" artifacts/install.log; then INSTALL_OK=1; echo "INSTALL: SUCCESS"; else echo "INSTALL: FAILED"; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 30

if [ "$INSTALL_OK" = "1" ]; then
  echo "== Case C: export novel 266817 (60 ch) through the 500-injecting proxy =="
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -n "$PDF_ACT" --el titleId 266817 -e title "test" 2>&1 | tee artifacts/caseC-start.log || true
  sleep 90
  adb -s "$DEV" exec-out screencap -p > artifacts/screen-caseC.png 2>/dev/null || true
  adb -s "$DEV" logcat -d > artifacts/logcat-caseC.txt 2>&1 || true
  adb -s "$DEV" shell dumpsys print > artifacts/dumpsys-caseC.txt 2>&1 || true
  # restore proxy (so later checks are not proxied)
  adb -s "$DEV" shell settings put global http_proxy :0 2>&1 || true
  docker cp mitm:/tmp/mitm-log.jsonl artifacts/mitm-log.jsonl 2>/dev/null || echo "mitm log docker-cp FAILED"
  if grep -q "injected-500" artifacts/mitm-log.jsonl 2>/dev/null; then
    INJECTED=1
    echo "500s WERE INJECTED (count: $(grep -c injected-500 artifacts/mitm-log.jsonl))"
  else
    echo "NO 500 injected — the proxy did not fire (test invalid)"
  fi
  if grep -qi "print_job_id" artifacts/dumpsys-caseC.txt 2>/dev/null; then
    echo "caseC: PRINT JOB EXISTS (BAD)"; echo "caseC_print_job=YES" >> artifacts/RESULT.md
  else
    echo "caseC: no print job (GOOD)"; echo "caseC_print_job=NO" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell "ls /sdcard/Download/*.pdf /sdcard/Documents/*.pdf 2>/dev/null" | grep -q .; then
    echo "caseC: PDF FILE EXISTS (BAD)"; echo "caseC_pdf=YES" >> artifacts/RESULT.md
  else
    echo "caseC: no PDF file (GOOD)"; echo "caseC_pdf=NO" >> artifacts/RESULT.md
  fi
  if grep -qi "FATAL EXCEPTION\|Fatal signal" artifacts/logcat-caseC.txt 2>/dev/null; then
    echo "caseC: FATAL/SIGSEGV found (BAD)"; echo "caseC_fatal=YES" >> artifacts/RESULT.md
  else
    echo "caseC: no FATAL (GOOD)"; echo "caseC_fatal=NO" >> artifacts/RESULT.md
  fi
  if adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; then echo "caseC: app alive (GOOD)"; else echo "caseC: app GONE (BAD)"; fi
fi

docker logs mitm > artifacts/mitm-docker.log 2>&1 || true
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
{
  echo "RESULT: install_ok=$INSTALL_OK mitm_ok=$MITM_OK ca_installed=$CA_INSTALLED injected500=$INJECTED"
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null) Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null) abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null)"
  echo "apk: $APK"
} | tee artifacts/RESULT.md
docker rm -f redroid mitm >/dev/null 2>&1 || true
if [ "$INSTALL_OK" = "1" ] && [ "$INJECTED" = "1" ]; then echo "DONE"; exit 0; fi
echo "DONE WITH FAILURES"; exit 1
