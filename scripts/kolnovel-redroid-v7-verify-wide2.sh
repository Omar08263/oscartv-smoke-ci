#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 4b — broad sweep ROUND 2 (fixes two harness bugs in
# the round-1 wide job, run 44466265799):
#  (a) library tab label is "مكتبة", not "المكتبة" (round 1 tapped nothing and
#      stayed on home); account tab is "الإعدادات" (proven round 1).
#  (b) chapter rows live BELOW the SeriesHeader — round 1 looked for "الفصل"
#      in the top dump without scrolling. This round scrolls the content tab
#      down to the chapter list, then taps "الفصل 1" and reads the reader.
# Everything else mirrors the round-1 wide job; verdicts are independent.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v7-common.sh
source scripts/kolnovel-redroid-v7-common.sh

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

step() {
  local label="$1" name="$2"
  sleep 3
  snap "$name"; dump_ui "$name"
  if alive; then echo "[$label] alive=YES" | tee -a "$RESULT"; else echo "[$label] alive=NO (APP DIED)" | tee -a "$RESULT"; fi
}

echo "== 1. home =="
step "home" "wide2-home"
grep -q "الرئيسية" artifacts/ui-wide2-home.xml 2>/dev/null && echo "home_tabs=YES" >> "$RESULT" || echo "home_tabs=NO" >> "$RESULT"

echo "== 2. library tab (label 'مكتبة') =="
LIB="not-found"
if tap_text "مكتبة"; then LIB="مكتبة"; fi
echo "library_tab_tapped=$LIB" | tee -a "$RESULT"
step "library" "wide2-library"
grep -qi "لم تضف أي رواية\|فارغة\|لا توجد\|أضف" artifacts/ui-wide2-library.xml 2>/dev/null && echo "library_empty_state=YES" >> "$RESULT" || echo "library_empty_state=?" >> "$RESULT"

echo "== 3. search + novel page =="
tap_text "الرئيسية" || true; sleep 3
adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "wide2-n1" "Reverend"
echo "wide2_n1_open=$OPEN_OK (1=ok 2=crashed 0=miss)" | tee -a "$RESULT"
if [ "$OPEN_OK" = "1" ]; then
  grep -q "تصدير PDF" artifacts/ui-wide2-n1-detail-top.xml 2>/dev/null && echo "wide2_button_visible_top=YES" >> "$RESULT" || echo "wide2_button_visible_top=NO" >> "$RESULT"
fi

echo "== 4. reader: content tab, SCROLL to chapters, open chapter 1 =="
READER="not-run"
if [ "$OPEN_OK" = "1" ]; then
  if tap_text "المحتوى"; then
    sleep 5
    echo "content_tab=opened" | tee -a "$RESULT"
    # Chapters are below the header: scroll up (content down) until a
    # "الفصل" row appears in the dump (max 6 swipes).
    FOUND=0
    for s in 1 2 3 4 5 6; do
      dump_ui "wide2-content-s$s" >/dev/null 2>&1
      if grep -q "الفصل" "artifacts/ui-wide2-content-s$s.xml" 2>/dev/null; then FOUND=1; echo "chapter rows visible after $s swipe(s)"; break; fi
      adb -s "$DEV" shell input swipe 360 1100 360 400 300 2>&1 || true
      sleep 3
    done
    echo "chapter_rows_found=$FOUND" | tee -a "$RESULT"
    if [ "$FOUND" = "1" ]; then
      snap "wide2-content-list"; cp "artifacts/ui-wide2-content-s$s.xml" "artifacts/ui-wide2-content-list.xml"
      if tap_regex "الفصل 1([^0-9]|$)" "artifacts/ui-wide2-content-list.xml" || tap_text "الفصل 1" || tap_regex "الفصل" "artifacts/ui-wide2-content-list.xml"; then
        sleep 10
        step "reader-ch1" "wide2-reader-ch1"
        READER="opened"
        grep -qi "الفصل" artifacts/ui-wide2-reader-ch1.xml 2>/dev/null && echo "reader_shows_chapter=YES" >> "$RESULT" || echo "reader_shows_chapter=?" >> "$RESULT"
      else
        echo "reader: chapter row not tappable" | tee -a "$RESULT"
        READER="row-not-tappable"
      fi
    else
      snap "wide2-content-norows"
      echo "reader: no chapter rows after 6 swipes" | tee -a "$RESULT"
      READER="no-chapter-rows"
    fi
  else
    echo "reader: المحتوى tab not tappable" | tee -a "$RESULT"
    READER="no-content-tab"
  fi
fi
echo "reader=$READER" | tee -a "$RESULT"

echo "== 5. back to detail, then home =="
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
step "back-to-detail" "wide2-back-detail"
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
step "back-to-home" "wide2-back-home"

echo "== 6. settings screen =="
ACCT="not-found"
if tap_text "الإعدادات"; then ACCT="الإعدادات"; fi
echo "settings_tab_tapped=$ACCT" | tee -a "$RESULT"
step "settings" "wide2-settings"

echo "== 7. navigation back and forth =="
tap_text "الرئيسية" || true; sleep 3
tap_text "مكتبة" || true; sleep 3
tap_text "الرئيسية" || true; sleep 3
step "nav-final" "wide2-nav-final"

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
  echo -n "Renderer crash not handled: "; grep -h "crash wasn't handled" artifacts/logcat-*.txt 2>/dev/null | wc -l
  echo "--- app FATAL excerpts (if any) ---"
  grep -h -A 8 "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | grep -i "KolNovelApp\|JavascriptException\|TypeError" | sort -u | head -20 || echo "(none)"
} | tee -a "$RESULT"
crash_scan
stop_redroid
echo "DONE wide2 n1_open=$OPEN_OK reader=$READER library=$LIB settings=$ACCT"
cat "$RESULT"
