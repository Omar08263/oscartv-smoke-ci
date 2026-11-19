#!/usr/bin/env bash
# Kolnovel v7 SMOKE — the gate before any wider v7 verification.
# v7 changes under test: (1) the export button moved OUT of fn 21721 (stock
# again) into fn 21728 (SeriesHeader title View, 3rd child, above the fold,
# coloured Text, pointerEvents box-none); (2) renderer-death retry dialog
# (Java — NOT exercised here; needs a renderer kill, separate run).
# This run answers ONLY:
#  (a) install v7 (sha verified in-run) + launch + home, no crash
#  (b) COLD open of novel 38916 «القس المجنون» VIA SEARCH (Latin "Reverend";
#      Arabic `adb input text` NPE-crashes on Redroid 13; detail verified
#      by title + the detail-only tab "المحتوى") — this is the crash path
#      that failed 2/2 on v6c with `TypeError: Cannot read property 'id'
#      of undefined` in SeriesListHeaderInner (fn 21721)
#  (c) UI dump of the detail page with NO scrolling must contain
#      "تصدير PDF" (the v7 button is above the fold by design)
#  (d) ONE tap on the button -> PdfExportActivity starts (logcat proof)
# A crash = the app process dies, or a FATAL EXCEPTION / SIGSEGV / ANR for
# our package appears in logcat. If (b) crashes, ONE relaunch + retry is
# allowed (to separate a cold-start flake from a deterministic crash);
# a crash on the retry FAILS the smoke.
# NOT tested here: parts 2-5, the full A/B matrix, the retry dialog —
# those are a separate later verification task.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v7.apk"
EXPECTED_SHA="7ecf32d6e5d5a75094f56078089a4a7547e5227751e1c3343f05f36ade2e30ed"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
TITLE1="القس المجنون"
RESULT="artifacts/RESULT.md"
: > "$RESULT"

dump_ui() {
  local name="$1"
  adb -s "$DEV" shell uiautomator dump /sdcard/ui-$name.xml 2>/dev/null
  adb -s "$DEV" pull /sdcard/ui-$name.xml artifacts/ui-$name.xml 2>/dev/null
}
snap() { # $1 = name
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
# tap first node whose text/content-desc matches a python regex; $1=regex, $2=dump file
tap_regex() {
  local rx="$1" f="$2"
  local bounds
  bounds=$(python3 - "$f" "$rx" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
f, rx = sys.argv[1], sys.argv[2]
try: root = ET.parse(f).getroot()
except Exception: sys.exit(1)
best = None
for node in root.iter('node'):
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if re.search(rx, t) or re.search(rx, cd):
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            cy = (y1+y2)//2
            if best is None or cy < best[0]:
                best = (cy, (x1+x2)//2, cy)
if best:
    print(best[1], best[2]); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  adb -s "$DEV" shell input tap $bounds 2>&1
  return 0
}
alive() { adb -s "$DEV" shell pidof "$PKG" 2>/dev/null | grep -q .; }
back() { adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3; }
crash_excerpt() { # $1=logcat file $2=out file
  grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal\|ANR in $PKG" "$1" > "$2" 2>/dev/null || true
}
dismiss_onboarding() {
  tap_text "Consent" || tap_text "consent" || true
  sleep 3
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || true
  sleep 5
}
relaunch() {
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee -a artifacts/launch.log || true
  sleep 15
  dismiss_onboarding
}
# open_novel_by_search $1=title $2=tag $3=latin query — assumes we are on HOME.
# Sets OPEN_OK=1/0/2 (ok / not-open / crashed). Diag2 harness fixes kept:
# Latin-only typing; detail verified by title + "المحتوى" tab; card-tap retry x3.
open_novel_by_search() {
  local title="$1" tag="$2" latin="$3"
  OPEN_OK=0
  tap_text "الرئيسية" || true; sleep 3
  tap_text "البحث عن رواية" || { echo "[$tag] search field NOT FOUND"; return 0; }
  sleep 3
  dump_ui "${tag}-search-empty"
  adb -s "$DEV" shell input text "$latin" 2>&1 || true
  sleep 5
  dump_ui "${tag}-search-results"
  if ! grep -q "$title" "artifacts/ui-${tag}-search-results.xml" 2>/dev/null; then
    echo "[$tag] Latin search '$latin' did NOT surface '$title'"
    snap "${tag}-search-noresult"
    return 0
  fi
  echo "[$tag] Latin search '$latin' surfaced '$title'"
  snap "${tag}-search-results"
  local tries=0
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    echo "[$tag] card-tap try $tries"
    tap_regex "فتح $title\$" "artifacts/ui-${tag}-search-results.xml" \
      || tap_text "$title" \
      || { echo "[$tag] card tap $tries: no tappable node"; sleep 3; continue; }
    sleep 10
    adb -s "$DEV" logcat -d > "artifacts/logcat-${tag}-open.txt" 2>&1 || true
    snap "${tag}-detail-top"
    dump_ui "${tag}-detail-top"
    if ! alive; then
      echo "[$tag] APP DIED opening detail (CRASH)"
      crash_excerpt "artifacts/logcat-${tag}-open.txt" "artifacts/crash-${tag}-open.txt"
      OPEN_OK=2
      return 0
    fi
    if grep -q "$title" "artifacts/ui-${tag}-detail-top.xml" 2>/dev/null \
       && grep -q "المحتوى" "artifacts/ui-${tag}-detail-top.xml" 2>/dev/null; then
      echo "[$tag] DETAIL OPEN OK (title + المحتوى tab in dump)"
      OPEN_OK=1
      return 0
    fi
    echo "[$tag] card tap $tries did NOT reach detail (still on search?); retrying"
    dump_ui "${tag}-search-results"
    sleep 3
  done
  echo "[$tag] DETAIL NEVER OPENED after 3 card taps"
  snap "${tag}-detail-never-opened"
  OPEN_OK=0
}

echo "== host =="
uname -m; nproc; free -h | head -2
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

echo "== (a) verify APK sha + install + launch =="
ACTUAL_SHA=$(sha256sum "$APK" | cut -d' ' -f1)
echo "apk sha256: $ACTUAL_SHA (expected $EXPECTED_SHA)" | tee -a "$RESULT"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] && echo "apk_sha=MATCH" >> "$RESULT" || echo "apk_sha=MISMATCH" >> "$RESULT"
adb -s "$DEV" logcat -c 2>&1 || true
adb -s "$DEV" install -r -g "$APK" 2>&1 | tee artifacts/install.log
INSTALL_OK=0
grep -q "Success" artifacts/install.log && INSTALL_OK=1
echo "install_ok=$INSTALL_OK" | tee -a "$RESULT"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi
adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee artifacts/launch.log || true
sleep 15
snap launch; dump_ui launch
dismiss_onboarding
snap home; dump_ui home
if grep -q "الرئيسية" artifacts/ui-home.xml 2>/dev/null; then echo "home_ok=1" >> "$RESULT"; else echo "home_ok=0 (tabs not in dump)" >> "$RESULT"; fi
if ! alive; then echo "APP DIED right after launch (CRASH)"; adb -s "$DEV" logcat -d > artifacts/logcat-launch-crash.txt 2>&1; crash_excerpt artifacts/logcat-launch-crash.txt artifacts/crash-launch.txt; fi

echo "== (b) cold open novel 38916 ($TITLE1) via search =="
open_novel_by_search "$TITLE1" "n1" "Reverend"
echo "n1_open=$OPEN_OK (1=ok 2=crashed 0=miss/search-fail)" | tee -a "$RESULT"
if [ "$OPEN_OK" = "2" ]; then
  echo "n1 detail-open CRASHED; ONE relaunch + retry (cold-start flake check)"
  relaunch
  open_novel_by_search "$TITLE1" "n1-retry" "Reverend"
  echo "n1_retry_open=$OPEN_OK" | tee -a "$RESULT"
  if [ "$OPEN_OK" = "1" ]; then
    # Normalise names so (c)/(d) below always read the successful attempt's files.
    cp artifacts/ui-n1-retry-detail-top.xml artifacts/ui-n1-detail-top.xml 2>/dev/null || true
    cp artifacts/screen-n1-retry-detail-top.png artifacts/screen-n1-detail-top.png 2>/dev/null || true
  fi
fi

SMOKE="FAIL"
if [ "$OPEN_OK" = "1" ]; then
  echo "== (c) export button visible at TOP with NO scrolling? =="
  # The detail-top dump was taken by open_novel_by_search with no scrolling.
  if grep -q "تصدير PDF" artifacts/ui-n1-detail-top.xml 2>/dev/null; then
    echo "export_visible_top=YES (تصدير PDF in ui-n1-detail-top.xml, no scroll)" | tee -a "$RESULT"
    grep -o "تصدير PDF[^<]*" artifacts/ui-n1-detail-top.xml | head -3 | tee -a "$RESULT"
    python3 - artifacts/ui-n1-detail-top.xml <<'PYEOF' | tee -a artifacts/RESULT.md
import sys, re, xml.etree.ElementTree as ET
try: root = ET.parse(sys.argv[1]).getroot()
except Exception as e: print("button nodes: dump unparsable", e); sys.exit(0)
n = 0
for node in root.iter('node'):
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if 'تصدير PDF' in t or 'تصدير PDF' in cd:
        n += 1
        print(f"button node {n}: class={node.get('class')} text={t!r} desc={cd!r} bounds={node.get('bounds')} clickable={node.get('clickable')}")
print(f"button_nodes_with_تصدير_PDF={n}")
PYEOF
  else
    echo "export_visible_top=NO (تصدير PDF absent from top dump)" | tee -a "$RESULT"
    _n=$(grep -c 'تصدير' artifacts/ui-n1-detail-top.xml 2>/dev/null || true)
    echo "export_word_present_anywhere=${_n:-0}" >> "$RESULT"
  fi

  echo "== (d) ONE tap on the export button -> PdfExportActivity? =="
  adb -s "$DEV" logcat -c 2>&1 || true
  PRESS="not-run"
  if grep -q "تصدير PDF" artifacts/ui-n1-detail-top.xml 2>/dev/null; then
    if tap_text "تصدير PDF"; then
      echo "export tap sent"
      PRESS="tap-sent"
    else
      echo "export tap FAILED (no tappable node)"
      PRESS="tap-failed"
    fi
  else
    echo "export tap SKIPPED (button not in top dump)"
    PRESS="button-not-found"
  fi
  echo "export_press=$PRESS" | tee -a "$RESULT"
  if [ "$PRESS" = "tap-sent" ]; then
    # Poll logcat up to 90 s for the Activity start; also watch for a crash
    # and for the part chooser (38916 has 2,355 chapters -> chooser expected).
    STARTED=0; CHOOSER=0; CRASHED=0
    for w in $(seq 1 9); do
      sleep 10
      adb -s "$DEV" logcat -d > artifacts/logcat-press.txt 2>&1 || true
      if grep -q "PdfExportActivity" artifacts/logcat-press.txt 2>/dev/null; then STARTED=1; fi
      dump_ui "press-w$w" >/dev/null 2>&1
      if grep -qi "اختر الجزء" "artifacts/ui-press-w$w.xml" 2>/dev/null; then CHOOSER=1; fi
      if ! alive; then CRASHED=1; break; fi
      if [ "$STARTED" = "1" ]; then break; fi
    done
    snap "press-aftertap"; dump_ui "press-aftertap"
    adb -s "$DEV" logcat -d > artifacts/logcat-press.txt 2>&1 || true
    grep -i "PdfExportActivity" artifacts/logcat-press.txt | head -10 > artifacts/pdfexport-start-lines.txt || true
    echo "press_pdfexport_started=$STARTED" | tee -a "$RESULT"
    echo "press_part_chooser=$CHOOSER" | tee -a "$RESULT"
    echo "press_app_crashed=$CRASHED" | tee -a "$RESULT"
    if [ "$CRASHED" = "1" ]; then
      crash_excerpt artifacts/logcat-press.txt artifacts/crash-press.txt
      echo "press_outcome=CRASH" | tee -a "$RESULT"
    elif [ "$STARTED" = "1" ]; then
      echo "press_outcome=PDFEXPORT_STARTED" | tee -a "$RESULT"
      cat artifacts/pdfexport-start-lines.txt | tee -a "$RESULT"
      SMOKE="PASS"
    else
      echo "press_outcome=NO_START_IN_90S" | tee -a "$RESULT"
    fi
  fi
else
  echo "SKIPPED (c)-(d): detail never opened (OPEN_OK=$OPEN_OK)" | tee -a "$RESULT"
fi

echo "== final crash scan =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
{
  echo "--- crash counts over ALL captured logcats ---"
  echo -n "FATAL EXCEPTION (all): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "FATAL EXCEPTION (KolNovelApp): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | grep -c "KolNovelApp\|com.benabdellah" || true
  echo -n "Fatal signal 11 (SIGSEGV): "; grep -h "Fatal signal 11" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 5 (SIGTRAP): "; grep -h "Fatal signal 5" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 6 (SIGABRT): "; grep -h "Fatal signal 6" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "ANR in KolNovelApp: "; grep -h "ANR in com.benabdellah" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JS TypeError lines: "; grep -h -i "TypeError" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JS JavascriptException lines: "; grep -h "JavascriptException" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Renderer crash not handled: "; grep -h "crash wasn't handled" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo "SMOKE=$SMOKE"
} | tee -a "$RESULT"
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE SMOKE=$SMOKE"
cat "$RESULT"
