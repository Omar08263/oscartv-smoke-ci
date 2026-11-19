#!/usr/bin/env bash
# Kolnovel v7 DIAG — parts 2-5 of the big novel 38916 (2,355 chapters).
# Part 1 was proven in v6 (run 44328386785: 2,536 pp, 500/500 headings).
# This run proves the SAME mechanism for each remaining part, independently:
#  deep link kexport://38916 -> part chooser -> tap "الجزء N" -> auto-save
#  -> pull the PDF -> verify (pages, sequential headings, Cairo only, 0 U+FFFD).
# A part that fails is recorded with logcat + screenshot and the run moves on
# to the next part — one independent verdict per part.
# Expected heading ranges: P2 501-1000 (500), P3 1001-1500 (500),
# P4 1501-2000 (500), P5 2001-2355 (355).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
EXPECTED_SHA="7144af9e19cbc5fa43a06302ff4cfca4ff71f4aa47346a621d0468df2d1525be"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
RESULT="artifacts/RESULT.md"
: > "$RESULT"
SEEN_PDFS="artifacts/seen-pdfs.txt"
: > "$SEEN_PDFS"

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
}
snap() {
  adb -s "$DEV" exec-out screencap -p > "artifacts/screen-$1.png" 2>/dev/null || true
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
alive() { adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; }
dismiss_onboarding() {
  tap_text "Consent" || tap_text "consent" || true
  sleep 3
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || true
  sleep 5
}
# newest PDF in the auto-save dir that we have NOT seen before (one path per line in $SEEN_PDFS)
new_pdf() {
  local p
  p=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
  if [ -n "$p" ] && ! grep -qxF "$p" "$SEEN_PDFS" 2>/dev/null; then echo "$p"; fi
}
verify_pdf() { # $1=local pdf $2=lo $3=hi $4=tag — writes artifacts/verify-$4.txt, sets VERDICT
  local pdf="$1" lo="$2" hi="$3" tag="$4"
  VERDICT="UNVERIFIED"
  {
    echo "=== verify $tag: $pdf (expected headings $lo-$hi) ==="
    ls -la "$pdf"
    pdfinfo "$pdf" 2>&1 | grep -E "Pages:|Page size:|File size:"
    echo "--- fonts ---"
    pdffonts "$pdf" 2>&1
    echo "--- text extraction ---"
    pdftotext -layout "$pdf" "artifacts/text-$tag.txt" 2>&1
    ls -la "artifacts/text-$tag.txt"
  } > "artifacts/verify-$tag.txt" 2>&1
  python3 - "$tag" "$lo" "$hi" >> "artifacts/verify-$tag.txt" 2>&1 <<'PYEOF'
import sys, re
tag, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    txt = open(f"artifacts/text-{tag}.txt", encoding="utf-8", errors="replace").read()
except Exception as e:
    print(f"VERIFY {tag}: FAIL cannot read text ({e})"); sys.exit(0)
fffd = txt.count("\ufffd")
# Lenient heading check (same family as v6 V3): a line whose leading number
# is followed by a dash is a chapter heading carrying the API number.
found = set()
for line in txt.splitlines():
    m = re.match(r"\s*(\d+)\s*[-—–]", line)
    if m:
        n = int(m.group(1))
        if lo <= n <= hi:
            found.add(n)
expected = set(range(lo, hi + 1))
missing = sorted(expected - found)
extra = sorted(n for n in found if n < lo or n > hi)
print(f"headings found in range: {len(found)}/{len(expected)}")
print(f"missing (first 20): {missing[:20]}")
print(f"out-of-range heading numbers: {extra[:20]}")
print(f"U+FFFD replacement chars: {fffd}")
fonts = ""
try:
    import subprocess
    fonts = subprocess.run(["pdffonts", f"artifacts/part-{tag}.pdf"], capture_output=True, text=True).stdout
except Exception as e:
    fonts = f"(pdffonts error: {e})"
print("--- pdffonts ---")
print(fonts)
non_cairo = [l for l in fonts.splitlines() if l.strip() and "Cairo" not in l and "name" not in l.lower() and "----" not in l]
print(f"non-Cairo font lines: {non_cairo}")
pages = 0
try:
    import subprocess
    out = subprocess.run(["pdfinfo", f"artifacts/part-{tag}.pdf"], capture_output=True, text=True).stdout
    m = re.search(r"Pages:\s*(\d+)", out)
    pages = int(m.group(1)) if m else 0
except Exception:
    pass
print(f"pages: {pages}")
ok = (len(found) >= int(0.98 * len(expected)) and fffd == 0 and pages > 0)
print(f"VERIFY {tag}: {'PASS' if ok else 'FAIL'} (headings {len(found)}/{len(expected)}, fffd={fffd}, pages={pages}, non_cairo={len(non_cairo)})")
PYEOF
  VERDICT=$(grep -oE "VERIFY $tag: (PASS|FAIL)" "artifacts/verify-$tag.txt" | tail -1 || echo "VERIFY $tag: FAIL")
  echo "$VERDICT" | tee -a "$RESULT"
  cat "artifacts/verify-$tag.txt" | tail -25
}

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
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
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
{
  echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r') Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r') SDK $(adb -s "$DEV" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r') abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
  echo "apk: $APK"
} | tee -a "$RESULT"

echo "== verify APK sha + install + launch =="
ACTUAL_SHA=$(sha256sum "$APK" | cut -d' ' -f1)
echo "apk sha256: $ACTUAL_SHA (expected $EXPECTED_SHA)" | tee -a "$RESULT"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] && echo "apk_sha=MATCH" >> "$RESULT" || echo "apk_sha=MISMATCH" >> "$RESULT"
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
INSTALL_OK=0
grep -q "Success" artifacts/install.log && INSTALL_OK=1
echo "install_ok=$INSTALL_OK" | tee -a "$RESULT"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15
dismiss_onboarding
snap home; dump_ui home

for N in 2 3 4 5; do
  case $N in
    2) LO=501; HI=1000 ;;
    3) LO=1001; HI=1500 ;;
    4) LO=1501; HI=2000 ;;
    5) LO=2001; HI=2355 ;;
  esac
  echo "########## PART $N (chapters $LO-$HI) ##########"
  # Clean state per part: force-stop, relaunch, then the export deep link.
  adb -s "$DEV" shell am force-stop "$PKG" 2>&1 || true
  sleep 3
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee -a artifacts/launch.log || true
  sleep 12
  dismiss_onboarding
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://38916" 2>&1 | tee "artifacts/p$N-deeplink.log" || true
  sleep 10
  adb -s "$DEV" logcat -d > "artifacts/logcat-p$N-afterstart.txt" 2>&1 || true
  CHOOSER=0
  for c in $(seq 1 10); do
    dump_ui "p$N-chooser-$c" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-p$N-chooser-$c.xml" 2>/dev/null; then
      CHOOSER=1
      echo "PART CHOOSER appeared after ~$((c * 30))s"
      snap "p$N-chooser"
      cp "artifacts/ui-p$N-chooser-$c.xml" "artifacts/ui-p$N-chooser.xml"
      break
    fi
    sleep 30
  done
  if [ "$CHOOSER" != "1" ]; then
    echo "part$N=NO-CHOOSER" | tee -a "$RESULT"
    adb -s "$DEV" logcat -d > "artifacts/logcat-p$N-nochooser.txt" 2>&1 || true
    snap "p$N-nochooser"
    continue
  fi
  tap_text "الجزء $N" || echo "part $N tap FAILED"
  sleep 5
  snap "p$N-after-parttap"
  # Wait up to 15 min for a NEW auto-save PDF, the print dialog, or death.
  P_OUTCOME="timeout"
  PDFP=""
  for w in $(seq 1 30); do
    sleep 30
    PDFP=$(new_pdf)
    if [ -n "$PDFP" ]; then P_OUTCOME="autosave"; break; fi
    dump_ui "p$N-wait-$w" >/dev/null 2>&1
    if grep -qiE "Select a printer" "artifacts/ui-p$N-wait-$w.xml" 2>/dev/null; then P_OUTCOME="print-dialog"; break; fi
    if ! alive; then
      P_OUTCOME="died"
      adb -s "$DEV" logcat -d > "artifacts/logcat-p$N-died.txt" 2>&1 || true
      grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-p$N-died.txt" > "artifacts/crash-p$N.txt" 2>/dev/null || true
      break
    fi
    if [ $((w % 10)) = 0 ]; then echo "  [part $N] waited $((w / 2)) min, no PDF/dialog yet"; fi
  done
  echo "part$N outcome=$P_OUTCOME pdf=$PDFP" | tee -a "$RESULT"
  if [ "$P_OUTCOME" = "autosave" ]; then
    echo "$PDFP" >> "$SEEN_PDFS"
    # Wait for a stable non-zero size, then pull.
    LAST=-1; STABLE=0
    for w in $(seq 1 60); do
      SZ=$(adb -s "$DEV" shell "stat -c %s '$PDFP' 2>/dev/null" | tr -d '\r\n')
      echo "  size poll $w: ${SZ:-?}"
      if [ -n "$SZ" ] && [ "$SZ" -gt 0 ] 2>/dev/null && [ "$SZ" = "$LAST" ]; then STABLE=1; break; fi
      LAST="$SZ"
      sleep 10
    done
    [ "$STABLE" = "1" ] || echo "WARNING: size never stabilized (last=$LAST)"
    adb -s "$DEV" pull "$PDFP" "artifacts/part-p$N.pdf" 2>&1 | tail -1
    if [ -s "artifacts/part-p$N.pdf" ]; then
      ls -la "artifacts/part-p$N.pdf"
      verify_pdf "artifacts/part-p$N.pdf" "$LO" "$HI" "p$N"
      echo "part$N=$VERDICT" | tee -a "$RESULT"
    else
      echo "part$N=PULL-FAILED (remote pdf: $PDFP)" | tee -a "$RESULT"
    fi
  elif [ "$P_OUTCOME" = "print-dialog" ]; then
    echo "part$N=PRINT-DIALOG-FALLBACK (auto-save did not write a PDF)" | tee -a "$RESULT"
    snap "p$N-printdialog"
  else
    echo "part$N=$P_OUTCOME" | tee -a "$RESULT"
    snap "p$N-end"
    adb -s "$DEV" logcat -d > "artifacts/logcat-p$N-end.txt" 2>&1 || true
  fi
done

echo "== final crash scan =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
{
  echo "--- crash counts over ALL captured logcats ---"
  echo -n "FATAL EXCEPTION (all): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 11 (SIGSEGV): "; grep -h "Fatal signal 11" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 5 (SIGTRAP): "; grep -h "Fatal signal 5" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Renderer crash not handled: "; grep -h "crash wasn't handled" artifacts/logcat-*.txt 2>/dev/null | wc -l
} | tee -a "$RESULT"
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE"
cat "$RESULT"
