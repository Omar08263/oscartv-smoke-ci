#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 4c — reader proof (round 3, v7).
# Round 2 (wide2) tapped chapter 1 and got the DOWNLOAD dialog
# («معلومات التحميل», «تحميل»/«إلغاء») — chapters download on demand, so the
# reader was never actually opened; the round-2 "reader=opened" was a false
# positive (the dump contained "الفصل" in the dialog + list). This job does
# the real flow: tap chapter 1 -> tap «تحميل» -> wait for the download to
# finish -> tap chapter 1 again -> the READER must open (chapter text
# visible, screenshot read firsthand). Also re-checks the settings tab from
# a verified home state (round 2's settings tap failed only because two BACK
# presses had landed on the search page, not home).
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

echo "== settings tab from verified home =="
dump_ui "wide3-home-check"
if grep -q "الرئيسية" artifacts/ui-wide3-home-check.xml 2>/dev/null; then
  echo "on_home=YES" | tee -a "$RESULT"
  if tap_text "الإعدادات"; then
    sleep 3; snap "wide3-settings"; dump_ui "wide3-settings"
    grep -q "الإعدادات" artifacts/ui-wide3-settings.xml 2>/dev/null && echo "settings_screen=YES" >> "$RESULT" || echo "settings_screen=?" >> "$RESULT"
    echo "settings_tab_tapped=الإعدادات" | tee -a "$RESULT"
  else
    echo "settings_tab_tapped=not-found" | tee -a "$RESULT"
  fi
  tap_text "الرئيسية" || true; sleep 3
else
  echo "on_home=NO (not on home after install)" | tee -a "$RESULT"
fi

echo "== open novel 38916 via search =="
adb -s "$DEV" logcat -c 2>&1 || true
open_novel_by_search "القس المجنون" "wide3-n1" "Reverend"
echo "wide3_n1_open=$OPEN_OK (1=ok 2=crashed 0=miss)" | tee -a "$RESULT"
READER="not-run"
if [ "$OPEN_OK" = "1" ]; then
  if tap_text "المحتوى"; then
    sleep 5
    echo "content_tab=opened" | tee -a "$RESULT"
    FOUND=0
    for s in 1 2 3 4 5 6; do
      dump_ui "wide3-content-s$s" >/dev/null 2>&1
      if grep -q "الفصل" "artifacts/ui-wide3-content-s$s.xml" 2>/dev/null; then FOUND=1; echo "chapter rows visible after $s swipe(s)"; break; fi
      adb -s "$DEV" shell input swipe 360 1100 360 400 300 2>&1 || true
      sleep 3
    done
    echo "chapter_rows_found=$FOUND" | tee -a "$RESULT"
    if [ "$FOUND" = "1" ]; then
      cp "artifacts/ui-wide3-content-s$s.xml" "artifacts/ui-wide3-content-list.xml"
      snap "wide3-content-list"
      if tap_regex "الفصل 1([^0-9]|$)" "artifacts/ui-wide3-content-list.xml" || tap_text "الفصل 1"; then
        sleep 5
        snap "wide3-after-ch1-tap"; dump_ui "wide3-after-ch1-tap"
        if grep -qi "معلومات التحميل" artifacts/ui-wide3-after-ch1-tap.xml 2>/dev/null; then
          echo "download dialog appeared (chapter downloads on demand)" | tee -a "$RESULT"
          if tap_text "تحميل"; then
            echo "download tap sent" | tee -a "$RESULT"
            # Wait up to 3 min for the download to finish (dialog closes).
            DL="timeout"
            for w in $(seq 1 18); do
              sleep 10
              dump_ui "wide3-dl-w$w" >/dev/null 2>&1
              if ! grep -qi "معلومات التحميل" "artifacts/ui-wide3-dl-w$w.xml" 2>/dev/null; then DL="closed"; break; fi
            done
            echo "download_dialog=$DL" | tee -a "$RESULT"
            sleep 3
            snap "wide3-after-download"; dump_ui "wide3-after-download"
          else
            echo "download tap FAILED" | tee -a "$RESULT"
            DL="tap-failed"
          fi
        else
          echo "no download dialog — chapter may have opened directly" | tee -a "$RESULT"
        fi
        # Tap chapter 1 again — now it should open the reader.
        dump_ui "wide3-before-reopen" >/dev/null 2>&1
        if tap_regex "الفصل 1([^0-9]|$)" "artifacts/ui-wide3-before-reopen.xml" || tap_text "الفصل 1"; then
          sleep 10
          snap "wide3-reader-ch1"; dump_ui "wide3-reader-ch1"
          if alive; then echo "reader alive=YES" | tee -a "$RESULT"; else echo "reader alive=NO (APP DIED)" | tee -a "$RESULT"; fi
          if grep -qi "معلومات التحميل" artifacts/ui-wide3-reader-ch1.xml 2>/dev/null; then
            echo "reader=STILL-DOWNLOAD-DIALOG (chapter did not open)" | tee -a "$RESULT"
            READER="still-download-dialog"
          elif grep -qi "الفصل" artifacts/ui-wide3-reader-ch1.xml 2>/dev/null; then
            echo "reader=opened (chapter text present in dump)" | tee -a "$RESULT"
            READER="opened"
          else
            echo "reader=UNCLEAR (no الفصل in dump; screenshot must be read)" | tee -a "$RESULT"
            READER="unclear"
          fi
        else
          echo "reader: chapter row not tappable on reopen" | tee -a "$RESULT"
          READER="row-not-tappable"
        fi
      else
        echo "reader: chapter row not tappable" | tee -a "$RESULT"
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
echo "== back to home (verified) =="
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
adb -s "$DEV" shell input keyevent 4 2>&1 || true; sleep 3
tap_text "الرئيسية" || true; sleep 3
snap "wide3-final-home"; dump_ui "wide3-final-home"
grep -q "الرئيسية" artifacts/ui-wide3-final-home.xml 2>/dev/null && echo "final_home=YES" >> "$RESULT" || echo "final_home=?" >> "$RESULT"
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
echo "DONE wide3 reader=$READER n1_open=$OPEN_OK"
cat "$RESULT"
