#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 4d — reader proof (round 4, v7).
# Round 3 (wide3) failed to tap any chapter row: the list has NO row labelled
# «الفصل 1» at the reached scroll position (rows are volume-grouped:
# «#0 · المقدمة», «#0 · أساطير رين زو - الجزء 1 - الفصل 5», ...), so the
# "الفصل 1" needle matched nothing. This job taps the FIRST chapter row
# («المقدمة») by coordinates, then the real flow: download dialog ->
# tap «تحميل» -> wait for the download -> tap the same row again -> the
# READER must open (chapter body text visible; screenshot read firsthand).
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v7-common.sh
source scripts/kolnovel-redroid-v7-common.sh

# tap_first_chapter_row $1=dump file — taps the first "#N · ..." row's center.
tap_first_chapter_row() {
  local f="$1"
  local bounds
  bounds=$(python3 - "$f" <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
f = sys.argv[1]
try: root = ET.parse(f).getroot()
except Exception: sys.exit(1)
for node in root.iter('node'):
    t = node.get('text') or ''
    if re.match(r"#\d+ ·", t):
        b = node.get('bounds') or ''
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print(f"{t}|{(x1+x2)//2} {(y1+y2)//2}"); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  echo "tapping first chapter row: $bounds"
  local xy="${bounds#*|}"
  adb -s "$DEV" shell input tap $xy 2>&1
  return 0
}

echo "== host =="
uname -m; nproc; free -h | head -2
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V7_APK" "$V7_SHA" "v7"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

echo "== open novel 38916 via search =="
adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "wide4-n1" "Reverend"
echo "wide4_n1_open=$OPEN_OK (1=ok 2=crashed 0=miss)" | tee -a "$RESULT"
READER="not-run"
if [ "$OPEN_OK" = "1" ]; then
  if tap_text "المحتوى"; then
    sleep 5
    echo "content_tab=opened" | tee -a "$RESULT"
    FOUND=0
    for s in 1 2 3 4 5 6; do
      dump_ui "wide4-content-s$s" >/dev/null 2>&1
      if grep -q "#0 ·" "artifacts/ui-wide4-content-s$s.xml" 2>/dev/null; then FOUND=1; echo "chapter rows visible after $s swipe(s)"; break; fi
      adb -s "$DEV" shell input swipe 360 1100 360 400 300 2>&1 || true
      sleep 3
    done
    echo "chapter_rows_found=$FOUND" | tee -a "$RESULT"
    if [ "$FOUND" = "1" ]; then
      cp "artifacts/ui-wide4-content-s$s.xml" "artifacts/ui-wide4-content-list.xml"
      snap "wide4-content-list"
      FIRST_ROW=$(python3 - artifacts/ui-wide4-content-list.xml <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter('node'):
    t = node.get('text') or ''
    if re.match(r"#\d+ ·", t):
        print(t); sys.exit(0)
PYEOF
)
      echo "first_row=$FIRST_ROW" | tee -a "$RESULT"
      if tap_first_chapter_row "artifacts/ui-wide4-content-list.xml"; then
        sleep 5
        snap "wide4-after-row-tap"; dump_ui "wide4-after-row-tap"
        if grep -qi "معلومات التحميل" artifacts/ui-wide4-after-row-tap.xml 2>/dev/null; then
          echo "download dialog appeared (chapter downloads on demand)" | tee -a "$RESULT"
          if tap_text "تحميل"; then
            echo "download tap sent" | tee -a "$RESULT"
            DL="timeout"
            for w in $(seq 1 18); do
              sleep 10
              dump_ui "wide4-dl-w$w" >/dev/null 2>&1
              if ! grep -qi "معلومات التحميل" "artifacts/ui-wide4-dl-w$w.xml" 2>/dev/null; then DL="closed"; break; fi
            done
            echo "download_dialog=$DL" | tee -a "$RESULT"
            sleep 3
            snap "wide4-after-download"; dump_ui "wide4-after-download"
          else
            echo "download tap FAILED" | tee -a "$RESULT"
          fi
        else
          echo "no download dialog — chapter may have opened directly" | tee -a "$RESULT"
        fi
        # Tap the same first row again — now the reader should open.
        dump_ui "wide4-before-reopen" >/dev/null 2>&1
        if tap_first_chapter_row "artifacts/ui-wide4-before-reopen.xml"; then
          sleep 10
          snap "wide4-reader"; dump_ui "wide4-reader"
          if alive; then echo "reader alive=YES" | tee -a "$RESULT"; else echo "reader alive=NO (APP DIED)" | tee -a "$RESULT"; fi
          if grep -qi "معلومات التحميل" artifacts/ui-wide4-reader.xml 2>/dev/null; then
            echo "reader=STILL-DOWNLOAD-DIALOG (chapter did not open)" | tee -a "$RESULT"
            READER="still-download-dialog"
          else
            echo "reader=reopened (no download dialog; screenshot must be read firsthand)" | tee -a "$RESULT"
            READER="reopened"
          fi
        else
          echo "reader: first row not found on reopen" | tee -a "$RESULT"
          READER="row-not-found-reopen"
        fi
      else
        echo "reader: first chapter row not tappable" | tee -a "$RESULT"
        READER="row-not-tappable"
      fi
    else
      echo "reader: no chapter rows after 6 swipes" | tee -a "$RESULT"
      READER="no-chapter-rows"
    fi
  else
    echo "reader: المحتوى tab not tappable" | tee -a "$RESULT"
    READER="no-content-tab"
  fi
fi
echo "reader=$READER" | tee -a "$RESULT"
echo "== final logcat scan =="
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
{
  echo "--- manual counts over all captured logcats ---"
  echo -n "FATAL EXCEPTION lines (all files): "; grep -h "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "ANR in app: "; grep -h "ANR in com.benabdellah" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JS TypeError lines: "; grep -h -i "TypeError" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "JavascriptException lines: "; grep -h "JavascriptException" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 11 (SIGSEGV): "; grep -h "Fatal signal 11" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo -n "Fatal signal 5 (SIGTRAP): "; grep -h "Fatal signal 5" artifacts/logcat-*.txt 2>/dev/null | wc -l
} | tee -a "$RESULT"
crash_scan
stop_redroid
echo "DONE wide4 reader=$READER n1_open=$OPEN_OK"
cat "$RESULT"
