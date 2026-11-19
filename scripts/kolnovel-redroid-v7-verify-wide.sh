#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 4 — broad sweep on v7 (Redroid 13).
# Home, Library tab, Search, novel page, Reader (open chapter 1),
# Account screen, back/forth navigation — with a logcat scan for
# FATAL/ANR/JS exceptions. Every screenshot is saved for firsthand reading.
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

step() { # $1=label $2=dump-name — record alive + screenshot + dump
  local label="$1" name="$2"
  sleep 3
  snap "$name"; dump_ui "$name"
  if alive; then echo "[$label] alive=YES" | tee -a "$RESULT"; else echo "[$label] alive=NO (APP DIED)" | tee -a "$RESULT"; fi
}

echo "== 1. home =="
step "home" "wide-home"
grep -q "الرئيسية" artifacts/ui-wide-home.xml 2>/dev/null && echo "home_tabs=YES" >> "$RESULT" || echo "home_tabs=NO" >> "$RESULT"

echo "== 2. library tab =="
LIB="not-found"
for t in "المكتبة" "المفضلة" "مكتبتي"; do
  if tap_text "$t"; then LIB="$t"; break; fi
done
echo "library_tab_tapped=$LIB" | tee -a "$RESULT"
step "library" "wide-library"
grep -qi "لم تضف أي رواية\|فارغة\|لا توجد" artifacts/ui-wide-library.xml 2>/dev/null && echo "library_empty_state=YES" >> "$RESULT" || echo "library_empty_state=?" >> "$RESULT"

echo "== 3. search + novel page =="
tap_text "الرئيسية" || true; sleep 3
adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "wide-n1" "Reverend"
echo "wide_n1_open=$OPEN_OK (1=ok 2=crashed 0=miss)" | tee -a "$RESULT"
if [ "$OPEN_OK" = "1" ]; then
  grep -q "تصدير PDF" artifacts/ui-wide-n1-detail-top.xml 2>/dev/null && echo "wide_button_visible_top=YES" >> "$RESULT" || echo "wide_button_visible_top=NO" >> "$RESULT"
fi

echo "== 4. reader: open chapter 1 =="
READER="not-run"
if [ "$OPEN_OK" = "1" ]; then
  if tap_text "المحتوى"; then
    sleep 5
    snap "wide-content"; dump_ui "wide-content"
    echo "content_tab=opened" | tee -a "$RESULT"
    # Tap the first chapter row: prefer "الفصل 1", else first node with الفصل.
    if tap_regex "الفصل 1([^0-9]|$)" "artifacts/ui-wide-content.xml" || tap_text "الفصل 1" || tap_regex "الفصل" "artifacts/ui-wide-content.xml"; then
      sleep 10
      step "reader-ch1" "wide-reader-ch1"
      READER="opened"
      grep -qi "الفصل" artifacts/ui-wide-reader-ch1.xml 2>/dev/null && echo "reader_shows_chapter=YES" >> "$RESULT" || echo "reader_shows_chapter=?" >> "$RESULT"
    else
      echo "reader: no chapter row tappable" | tee -a "$RESULT"
      READER="no-chapter-row"
    fi
  else
    echo "reader: المحتوى tab not tappable" | tee -a "$RESULT"
    READER="no-content-tab"
  fi
fi
echo "reader=$READER" | tee -a "$RESULT"

echo "== 5. back to detail, then home =="
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
step "back-to-detail" "wide-back-detail"
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
step "back-to-home" "wide-back-home"

echo "== 6. account screen =="
ACCT="not-found"
for t in "حسابي" "الحساب" "الإعدادات" "الملف الشخصي"; do
  if tap_text "$t"; then ACCT="$t"; break; fi
done
echo "account_tab_tapped=$ACCT" | tee -a "$RESULT"
step "account" "wide-account"

echo "== 7. navigation back and forth =="
tap_text "الرئيسية" || true; sleep 3
tap_text "المكتبة" || tap_text "المفضلة" || true; sleep 3
tap_text "الرئيسية" || true; sleep 3
step "nav-final" "wide-nav-final"

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
echo "DONE wide n1_open=$OPEN_OK reader=$READER account=$ACCT"
cat "$RESULT"
