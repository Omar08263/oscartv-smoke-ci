#!/usr/bin/env bash
# Kolnovel v7 DIAG — broad stability sweep of v6 (v6c) on Redroid (arm64, NO KVM).
# Omar's complaint (2026-11-19): the app has many problems, crashes fast,
# and the PDF-export button is missing.
# Known facts (built on, not re-proven): the patch IS in the signed v6
# (bundle sha 95ffc248..., PdfExportActivity in classes2.dex), but in the
# v6c run (crashab-v6c-44327359581) no "تصدير PDF" button is visible at the
# top of the novel detail page and the word "تصدير" is absent (0x) from
# ui-v6-c2/c3/c4.xml — the button lives in the content-tab header (fn 21721)
# under the cover, i.e. below the fold on open. Known flake: 1/4 JS TypeError
# on detail-open on Redroid.
# This run answers, with screenshots + UI dumps + logcat as evidence:
#  (a) install v6 (sha verified in-run) + launch + home
#  (b) Library tab, then search "القس المجنون" and open novel 38916
#  (c) detail page: is "تصدير PDF" visible at the TOP? then scroll down to
#      the chapter list: does it appear in the header? screenshot + read it
#  (d) open chapter 1 in the reader, then back
#  (e) account/settings screen
#  (f) press the export button (after scrolling to it) 3x in a row
#      (relaunch between attempts if it crashes); record each outcome:
#      part chooser / export opened, or crash?
#  (g) open a second novel 76237 "جمر الليل الأبدي" and repeat (c) and (f) once
# A crash = the app process dies within ~15 s of the action, or a
# FATAL EXCEPTION / SIGSEGV / ANR for our package appears in logcat.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1

APK="app/Kolnovel-v5.2.5-premium-v6.apk"
EXPECTED_SHA="7144af9e19cbc5fa43a06302ff4cfca4ff71f4aa47346a621d0468df2d1525be"
PKG="com.benabdellah.KolNovelApp"
ACT="com.benabdellah.KolNovelApp/.MainActivity"
DEV="localhost:5555"
TITLE1="القس المجنون"
TITLE2="جمر الليل الأبدي"
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
scroll_down() { adb -s "$DEV" shell input swipe 360 1000 360 350 300 2>&1 || true; sleep 2; }
scroll_up() { adb -s "$DEV" shell input swipe 360 350 360 1000 300 2>&1 || true; sleep 2; }
back() { adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3; }
# find_export_button $1=tag — scrolls up to 8x looking for "تصدير" in UI dumps.
# Sets EXPORT_FOUND=1/0, EXPORT_Y=y-coord (or empty), EXPORT_DUMP=dump name.
find_export_button() {
  local tag="$1"
  EXPORT_FOUND=0; EXPORT_Y=""; EXPORT_DUMP=""
  for s in $(seq 0 8); do
    dump_ui "${tag}-s$s"
    if grep -q "تصدير" "artifacts/ui-${tag}-s$s.xml" 2>/dev/null; then
      EXPORT_FOUND=1; EXPORT_DUMP="ui-${tag}-s$s.xml"
      EXPORT_Y=$(python3 - "artifacts/ui-${tag}-s$s.xml" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
try: root = ET.parse(sys.argv[1]).getroot()
except Exception: sys.exit(1)
for node in root.iter('node'):
    t = node.get('text') or ''
    cd = node.get('content-desc') or ''
    if 'تصدير' in t or 'تصدير' in cd:
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print(f"text={t!r} desc={cd!r} bounds={b} center={((x1+x2)//2,(y1+y2)//2)}"); sys.exit(0)
sys.exit(1)
PYEOF
)
      echo "[$tag] EXPORT BUTTON FOUND after $s scroll(s): $EXPORT_Y"
      return 0
    fi
    scroll_down
  done
  echo "[$tag] EXPORT BUTTON NOT FOUND after 9 dumps"
  return 1
}
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
# open_novel_by_search $1=title $2=tag — assumes we are on HOME. Sets OPEN_OK=1/0.
open_novel_by_search() {
  local title="$1" tag="$2"
  OPEN_OK=0
  tap_text "الرئيسية" || true; sleep 3
  tap_text "البحث عن رواية" || { echo "[$tag] search field NOT FOUND"; return 0; }
  sleep 3
  dump_ui "${tag}-search-empty"
  local query_esc
  query_esc=$(echo "$title" | sed 's/ /%s/g')
  adb -s "$DEV" shell input text "$query_esc" 2>&1 || true
  sleep 5
  dump_ui "${tag}-search-results"
  if grep -q "$title" "artifacts/ui-${tag}-search-results.xml" 2>/dev/null; then
    echo "[$tag] search found '$title' (Arabic input worked)"
  else
    echo "[$tag] Arabic search did NOT surface '$title'; trying Latin 'Reverend'"
    tap_text "البحث عن رواية" || true; sleep 2
    adb -s "$DEV" shell input text "Reverend" 2>&1 || true
    sleep 5
    dump_ui "${tag}-search-results-latin"
    if grep -q "$title" "artifacts/ui-${tag}-search-results-latin.xml" 2>/dev/null || grep -qi "Reverend" "artifacts/ui-${tag}-search-results-latin.xml" 2>/dev/null; then
      echo "[$tag] Latin search surfaced a result"
    else
      echo "[$tag] SEARCH FAILED for '$title' (both Arabic and Latin)"
      return 0
    fi
  fi
  snap "${tag}-search-results"
  tap_text "$title" || tap_regex "Reverend" "artifacts/ui-${tag}-search-results-latin.xml" || { echo "[$tag] result tap FAILED"; return 0; }
  sleep 12
  adb -s "$DEV" logcat -d > "artifacts/logcat-${tag}-open.txt" 2>&1 || true
  snap "${tag}-detail-top"
  dump_ui "${tag}-detail-top"
  if ! alive; then
    echo "[$tag] APP DIED opening detail (CRASH)"
    crash_excerpt "artifacts/logcat-${tag}-open.txt" "artifacts/crash-${tag}-open.txt"
    OPEN_OK=2
    return 0
  fi
  if grep -q "$title" "artifacts/ui-${tag}-detail-top.xml" 2>/dev/null; then
    echo "[$tag] DETAIL OPEN OK ('$title' in dump)"
    OPEN_OK=1
  else
    echo "[$tag] ALIVE but detail title NOT in dump (miss or slow load)"
    OPEN_OK=0
  fi
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

echo "== (b) Library tab =="
tap_text "مكتبة" || echo "library tab tap FAILED"
sleep 5
snap library; dump_ui library
echo "library_dump_nodes=$(python3 -c "import xml.etree.ElementTree as ET; print(len(list(ET.parse('artifacts/ui-library.xml').getroot().iter('node'))))" 2>/dev/null || echo '?')" >> "$RESULT"
tap_text "الرئيسية" || true; sleep 3

echo "== (b) search + open novel 38916 ($TITLE1) =="
open_novel_by_search "$TITLE1" "n1"
echo "n1_open=$OPEN_OK (1=ok 2=crashed 0=miss/search-fail)" | tee -a "$RESULT"
if [ "$OPEN_OK" = "2" ]; then
  echo "n1 detail-open CRASHED; relaunching for a retry"
  relaunch
  open_novel_by_search "$TITLE1" "n1-retry"
  echo "n1_retry_open=$OPEN_OK" | tee -a "$RESULT"
fi

if [ "$OPEN_OK" = "1" ]; then
  echo "== (c) novel 38916: export button at TOP? =="
  if grep -q "تصدير" artifacts/ui-n1-detail-top.xml 2>/dev/null; then
    echo "n1_export_visible_top=YES" | tee -a "$RESULT"
  else
    echo "n1_export_visible_top=NO (word 'تصدير' absent from top dump)" | tee -a "$RESULT"
  fi
  echo "== (c) scroll down to chapter list: button in header? =="
  find_export_button "n1-detail" || true
  snap "n1-detail-button"
  echo "n1_export_found_after_scroll=$EXPORT_FOUND y_info: $EXPORT_Y" | tee -a "$RESULT"
  echo "n1_export_dump=$EXPORT_DUMP" >> "$RESULT"

  echo "== (d) open chapter 1 in reader =="
  CH1_OK=0
  dump_ui "n1-chapters"
  if tap_regex "الفصل\s*1\b" "artifacts/ui-n1-chapters.xml" || tap_regex "الفصل" "artifacts/ui-n1-chapters.xml"; then
    sleep 10
    snap "n1-reader"; dump_ui "n1-reader"
    adb -s "$DEV" logcat -d > artifacts/logcat-n1-reader.txt 2>&1 || true
    if ! alive; then
      echo "n1 chapter-1: APP DIED in reader (CRASH)"; crash_excerpt artifacts/logcat-n1-reader.txt artifacts/crash-n1-reader.txt; CH1_OK=2
      relaunch; open_novel_by_search "$TITLE1" "n1-after-reader-crash" || true
    elif grep -qi "الفصل" artifacts/ui-n1-reader.xml 2>/dev/null; then
      echo "n1 chapter-1: READER OK"; CH1_OK=1
    else
      echo "n1 chapter-1: alive, reader content unclear"; CH1_OK=0
    fi
  else
    echo "n1 chapter-1: NO chapter row found to tap"
    snap "n1-no-chapter-row"
  fi
  echo "n1_chapter1=$CH1_OK (1=ok 2=crashed 0=unclear/not-found)" | tee -a "$RESULT"
  back; back
  sleep 3; dump_ui "n1-after-reader-back"; snap "n1-after-reader-back"

  echo "== (e) account/settings screen =="
  tap_text "الرئيسية" || true; sleep 3
  tap_text "الإعدادات" || tap_text "النشاط" || echo "settings/activity tab tap FAILED"
  sleep 5
  snap "settings"; dump_ui "settings"
  if grep -qi "حساب\|تسجيل الدخول" artifacts/ui-settings.xml 2>/dev/null; then echo "settings_shows_account_area=YES" >> "$RESULT"; else echo "settings_shows_account_area=NO" >> "$RESULT"; fi
  tap_text "الرئيسية" || true; sleep 3

  echo "== (f) export button x3 for novel 38916 =="
  # Return to the novel detail: re-open via search (deterministic).
  open_novel_by_search "$TITLE1" "n1-exp0" || true
  for att in 1 2 3; do
    echo "---- export attempt $att (38916) ----"
    adb -s "$DEV" logcat -c 2>&1 || true
    ATT_OUTCOME="not-run"
    if [ "$OPEN_OK" != "1" ]; then
      echo "attempt $att: detail NOT open (OPEN_OK=$OPEN_OK), cannot press export"
      ATT_OUTCOME="detail-not-open"
      echo "n1_export_attempt$att=$ATT_OUTCOME" | tee -a "$RESULT"
      relaunch; open_novel_by_search "$TITLE1" "n1-exp$att-retry" || true
      continue
    fi
    find_export_button "n1-exp$att" || true
    snap "n1-exp$att-button"
    if [ "$EXPORT_FOUND" != "1" ]; then
      ATT_OUTCOME="button-not-found"
      echo "n1_export_attempt$att=$ATT_OUTCOME" | tee -a "$RESULT"
      continue
    fi
    tap_text "تصدير PDF" || tap_text "تصدير" || { echo "attempt $att: export tap FAILED"; ATT_OUTCOME="tap-failed"; echo "n1_export_attempt$att=$ATT_OUTCOME" | tee -a "$RESULT"; continue; }
    sleep 8
    snap "n1-exp$att-aftertap"; dump_ui "n1-exp$att-aftertap"
    adb -s "$DEV" logcat -d > "artifacts/logcat-n1-exp$att-aftertap.txt" 2>&1 || true
    if ! alive; then
      ATT_OUTCOME="crash-on-tap"
      crash_excerpt "artifacts/logcat-n1-exp$att-aftertap.txt" "artifacts/crash-n1-exp$att.txt"
      echo "n1_export_attempt$att=$ATT_OUTCOME" | tee -a "$RESULT"
      relaunch; open_novel_by_search "$TITLE1" "n1-exp$att-relaunch" || true
      continue
    fi
    # Wait for the part chooser (38916 has 2,355 ch -> chooser expected).
    CHOOSER=0
    for c in $(seq 1 4); do
      dump_ui "n1-exp$att-chooser-$c" >/dev/null 2>&1
      if grep -qi "اختر الجزء" "artifacts/ui-n1-exp$att-chooser-$c.xml" 2>/dev/null; then CHOOSER=1; break; fi
      sleep 30
    done
    if [ "$CHOOSER" = "1" ]; then
      echo "attempt $att: PART CHOOSER appeared"
      snap "n1-exp$att-chooser"
      cp "artifacts/ui-n1-exp$att-chooser-$c.xml" "artifacts/ui-n1-exp$att-chooser.xml" 2>/dev/null || true
      tap_text "الجزء 1" || echo "attempt $att: Part-1 tap FAILED"
      sleep 5
    else
      echo "attempt $att: NO part chooser (export may have gone straight to PdfExportActivity or failed silently)"
    fi
    # Wait up to 6 min: auto-save PDF appears, print dialog appears, or app dies.
    ATT_OUTCOME="timeout"
    for w in $(seq 1 12); do
      sleep 30
      PDFP=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
      if [ -n "$PDFP" ]; then ATT_OUTCOME="autosave-pdf:$PDFP"; break; fi
      dump_ui "n1-exp$att-wait-$w" >/dev/null 2>&1
      if grep -qiE "Select a printer" "artifacts/ui-n1-exp$att-wait-$w.xml" 2>/dev/null; then ATT_OUTCOME="print-dialog"; break; fi
      if ! alive; then
        ATT_OUTCOME="crash-during-export"
        adb -s "$DEV" logcat -d > "artifacts/logcat-n1-exp$att-crash.txt" 2>&1 || true
        crash_excerpt "artifacts/logcat-n1-exp$att-crash.txt" "artifacts/crash-n1-exp$att.txt"
        break
      fi
    done
    echo "n1_export_attempt$att=$ATT_OUTCOME (chooser=$CHOOSER)" | tee -a "$RESULT"
    snap "n1-exp$att-end"; dump_ui "n1-exp$att-end"
    adb -s "$DEV" logcat -d > "artifacts/logcat-n1-exp$att-end.txt" 2>&1 || true
    if [ "$ATT_OUTCOME" = "crash-during-export" ]; then
      relaunch; open_novel_by_search "$TITLE1" "n1-exp$att-relaunch2" || true
    else
      # Dismiss share sheet / PdfExportActivity and get back to the detail page.
      back; back; sleep 3
      dump_ui "n1-exp$att-backcheck"
      if ! grep -q "$TITLE1" "artifacts/ui-n1-exp$att-backcheck.xml" 2>/dev/null; then
        echo "attempt $att: not back on detail; re-opening via search"
        open_novel_by_search "$TITLE1" "n1-exp$att-reopen" || true
      else
        OPEN_OK=1
        # Re-dump the top for the next attempt's scroll baseline.
        dump_ui "n1-exp$att-detail-top"
      fi
    fi
  done
else
  echo "SKIPPED (c)-(f) for 38916: detail never opened (OPEN_OK=$OPEN_OK)" | tee -a "$RESULT"
fi

echo "== (g) second novel 76237 ($TITLE2) =="
tap_text "الرئيسية" || true; sleep 3
snap "home-before-n2"; dump_ui "home-before-n2"
# 76237 is on the home feed ("فتح جمر الليل الأبدي"); try the feed card first.
tap_text "$TITLE2" || open_novel_by_search "$TITLE2" "n2" || true
sleep 12
snap "n2-detail-top"; dump_ui "n2-detail-top"
adb -s "$DEV" logcat -d > artifacts/logcat-n2-open.txt 2>&1 || true
N2_OK=0
if ! alive; then
  echo "n2 detail-open CRASHED"; crash_excerpt artifacts/logcat-n2-open.txt artifacts/crash-n2-open.txt; N2_OK=2
elif grep -q "$TITLE2" artifacts/ui-n2-detail-top.xml 2>/dev/null; then
  echo "n2 DETAIL OPEN OK"; N2_OK=1
else
  echo "n2 detail open unclear (alive, title not in dump)"; N2_OK=0
fi
echo "n2_open=$N2_OK (1=ok 2=crashed 0=unclear)" | tee -a "$RESULT"
if [ "$N2_OK" = "1" ]; then
  if grep -q "تصدير" artifacts/ui-n2-detail-top.xml 2>/dev/null; then
    echo "n2_export_visible_top=YES" | tee -a "$RESULT"
  else
    echo "n2_export_visible_top=NO" | tee -a "$RESULT"
  fi
  find_export_button "n2-detail" || true
  snap "n2-detail-button"
  echo "n2_export_found_after_scroll=$EXPORT_FOUND y_info: $EXPORT_Y" | tee -a "$RESULT"
  echo "n2_export_dump=$EXPORT_DUMP" >> "$RESULT"
  if [ "$EXPORT_FOUND" = "1" ]; then
    echo "---- export attempt 1 (76237, no chooser expected) ----"
    adb -s "$DEV" logcat -c 2>&1 || true
    tap_text "تصدير PDF" || tap_text "تصدير" || echo "n2 export tap FAILED"
    sleep 8
    snap "n2-exp1-aftertap"; dump_ui "n2-exp1-aftertap"
    N2_EXP="timeout"
    for w in $(seq 1 12); do
      sleep 30
      PDFP=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
      if [ -n "$PDFP" ]; then N2_EXP="autosave-pdf:$PDFP"; break; fi
      dump_ui "n2-exp1-wait-$w" >/dev/null 2>&1
      if grep -qiE "Select a printer" "artifacts/ui-n2-exp1-wait-$w.xml" 2>/dev/null; then N2_EXP="print-dialog"; break; fi
      if ! alive; then
        N2_EXP="crash-during-export"
        adb -s "$DEV" logcat -d > artifacts/logcat-n2-exp1-crash.txt 2>&1 || true
        crash_excerpt artifacts/logcat-n2-exp1-crash.txt artifacts/crash-n2-exp1.txt
        break
      fi
    done
    echo "n2_export_attempt1=$N2_EXP" | tee -a "$RESULT"
    snap "n2-exp1-end"; dump_ui "n2-exp1-end"
  else
    echo "n2_export_attempt1=button-not-found" | tee -a "$RESULT"
  fi
fi

echo "== final crash scan =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
{
  echo "--- crash counts over ALL captured logcats (our package only where noted) ---"
  echo -n "FATAL EXCEPTION (all): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "FATAL EXCEPTION (KolNovelApp pid lines): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | grep -c "KolNovelApp\|com.benabdellah" || true
  echo -n "Fatal signal 11 (SIGSEGV): "; grep -h "Fatal signal 11" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 5 (SIGTRAP): "; grep -h "Fatal signal 5" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 6 (SIGABRT): "; grep -h "Fatal signal 6" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "ANR in KolNovelApp: "; grep -h "ANR in com.benabdellah" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JS TypeError lines: "; grep -h -i "TypeError" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JS JavascriptException lines: "; grep -h "JavascriptException" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Renderer crash not handled: "; grep -h "crash wasn't handled" artifacts/logcat-*.txt 2>/dev/null | wc -l
} | tee -a "$RESULT"
docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
docker rm -f redroid >/dev/null 2>&1 || true
echo "DONE"
cat "$RESULT"
