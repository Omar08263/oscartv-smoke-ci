#!/usr/bin/env bash
# Kolnovel v8.6 VERIFY job 1 — parts: ONLY NEW part 5 (38916, ch 1001-1250)
# on v8.6, via deep link kexport://38916. Light export regression only:
# export code is byte-identical to v8.2, so one 250-ch part confirms no
# regression (v8.2 reference: 7,324 pages = Chrome oracle حرفيًا, write ~100s).
# Picker must show 10 parts. Record real page count + write time; PDFs get
# the v8.6 reference-spec checks (Letter / 21pt / margins / no TOC / zero rights).
# 240 s latch unchanged; a timeout dialog here is TIMEOUT-DIALOG evidence.
# v8.1 CHANGE vs v8 (VERIFY-V8.1 task §ج6): if the 240 s timeout dialog
# appears, TAP «إعادة المحاولة» INSIDE that dialog (never tested live) and
# wait for the fresh export — one retry-tap per attempt; the dialog + tap +
# fresh outcome are all logged. The v8 "never auto-tap" rule is DELIBERATELY
# lifted here by the v8.1 task: the retry-in-timeout-dialog path itself is
# under test, and a second timeout dialog after the tap still ends the
# attempt as TIMEOUT-DIALOG (with the retry-tapped note).
# Harness fixes carried from parts3.sh: stale part PDF deleted before each
# attempt (same filename broke new_pdf detection); FILE-GONE early stop in
# the stable pull; logcat snapshots every 2 min during the wait.
# HARNESS FIX 2 (run 44478047693, proven): seen-pdfs.txt is cleared per
# attempt — the previous attempt's identical filename hid the new file from
# new_pdf() (p3a2: file opened +55s, print dialog at +224s, loop never saw
# the file). FILE-GONE branch also checks for the system print dialog so a
# layout-timeout fallback keeps its PRINT-DIALOG-FALLBACK verdict.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v8.6-common.sh
source scripts/kolnovel-redroid-v8.6-common.sh

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V8_APK" "$V8_SHA" "${VARIANT:-v8.6}"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

# dialog_check $1=ui-dump-file — prints which retry dialog (if any) is visible.
# Sets DIALOG_KIND to none|timeout|renderer|unknown.
dialog_check() {
  local f="$1"
  DIALOG_KIND="none"
  if grep -q "إعادة المحاولة" "$f" 2>/dev/null; then
    if grep -q "تعذّر إكمال التصدير" "$f" 2>/dev/null; then DIALOG_KIND="timeout"
    elif grep -q "تعطّل عارض العرض أثناء التصدير" "$f" 2>/dev/null; then DIALOG_KIND="renderer"
    else DIALOG_KIND="unknown"; fi
  fi
  echo "dialog=$DIALOG_KIND"
}

# export_part $1=N $2=LO $3=HI $4=attempt-tag (e.g. a1) $5=expected picker parts.
# Sets PART_VERDICT. v8.2: part tap uses anchored regex "^الجزء N —" so
# "الجزء 1" never matches "الجزء 10"; picker part count is logged+checked.
# v8.1 CHANGE vs v8: if the 240 s TIMEOUT dialog appears, TAP «إعادة
# المحاولة» in THAT dialog (never tested live before — VERIFY-V8 §a5) and
# wait for the fresh export; one retry-tap per attempt. A second timeout
# dialog after the tap ends the attempt as TIMEOUT-DIALOG (with the
# retry-tapped note). Write time is measured: FILE_SEEN_EPOCH (first
# new_pdf sighting) -> STABLE_EPOCH (two stable non-zero size polls
# 10 s apart) = write_time_s, logged to $RESULT.
export_part() {
  local n="$1" lo="$2" hi="$3" atag="$4" exp_parts="${5:-0}"
  local tag="p${n}${atag}"
  PART_VERDICT="UNVERIFIED"
  echo "########## PART $n (chapters $lo-$hi) attempt $atag ##########"
  delete_old_pdfs
  cold_relaunch
  adb -s "$DEV" logcat -c 2>&1 || true
  adb -s "$DEV" shell am start -a android.intent.action.VIEW -d "kexport://38916" 2>&1 | tee "artifacts/$tag-deeplink.log" || true
  sleep 10
  adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-afterstart.txt" 2>&1 || true
  local chooser=0
  for c in $(seq 1 15); do
    dump_ui "$tag-chooser-$c" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-$tag-chooser-$c.xml" 2>/dev/null; then
      chooser=1
      echo "PART CHOOSER appeared (poll $c)"
      snap "$tag-chooser"
      cp "artifacts/ui-$tag-chooser-$c.xml" "artifacts/ui-$tag-chooser.xml"
      break
    fi
    sleep 20
  done
  if [ "$chooser" != "1" ]; then
    echo "$tag=NO-CHOOSER" | tee -a "$RESULT"
    adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-nochooser.txt" 2>&1 || true
    snap "$tag-nochooser"
    PART_VERDICT="NO-CHOOSER"
    return 0
  fi
  # v8.2: count parts offered in the chooser (38916 -> 10, 76237 -> 2).
  local parts_seen=0
  parts_seen=$(grep -oE 'الجزء [0-9]+' "artifacts/ui-$tag-chooser.xml" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  echo "$tag chooser_parts_seen=$parts_seen (expected $exp_parts)" | tee -a "$RESULT"
  grep -oE 'الجزء [0-9]+[^<]{0,60}' "artifacts/ui-$tag-chooser.xml" 2>/dev/null | sort -u | head -15 | tee -a "$RESULT" || true
  # v8.2: count mismatch is RECORDED, never fatal to the export attempt —
  # the dump may list a part number twice (label + count text) or use a
  # different dash; the verdict on the picker is judged from the dump.
  if [ "$exp_parts" != "0" ] && [ "$parts_seen" != "$exp_parts" ]; then
    echo "$tag chooser_parts_MISMATCH (chooser shows $parts_seen distinct part numbers, expected $exp_parts — see dump)" | tee -a "$RESULT"
  fi
  if ! tap_regex "^الجزء $n " "artifacts/ui-$tag-chooser.xml" && ! tap_text "الجزء $n"; then
    echo "$tag=PART-TAP-FAILED" | tee -a "$RESULT"
    snap "$tag-parttap-failed"
    PART_VERDICT="PART-TAP-FAILED"
    return 0
  fi
  sleep 5
  snap "$tag-after-parttap"
  local tap_epoch=$(date +%s)
  local retry_tapped=0 retry_tap_epoch=0
  local round=1
  while [ "$round" -le 2 ]; do
    echo "--- $tag round $round (retry_tapped=$retry_tapped) ---"
    local outcome="timeout" pdfp="" dialog_kind="none"
    local file_seen_epoch=0
    local w=0
    while [ "$w" -lt 40 ]; do
      w=$((w + 1))
      sleep 30
      pdfp=$(new_pdf)
      if [ -n "$pdfp" ]; then outcome="autosave"; file_seen_epoch=$(date +%s); break; fi
      dump_ui "$tag-wait-$w" >/dev/null 2>&1
      dialog_check "artifacts/ui-$tag-wait-$w.xml"
      if [ "$DIALOG_KIND" != "none" ]; then
        dialog_kind="$DIALOG_KIND"
        # v8.1: tap retry INSIDE the timeout dialog (once per attempt).
        if [ "$DIALOG_KIND" = "timeout" ] && [ "$retry_tapped" = "0" ]; then
          echo "  [$tag] TIMEOUT dialog seen at wait $w (+$(( $(date +%s) - tap_epoch ))s) — TAPPING «إعادة المحاولة» in it (first live test of this path)"
          snap "$tag-dialog-before-retrytap"
          cp "artifacts/ui-$tag-wait-$w.xml" "artifacts/ui-$tag-dialog.xml"
          adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-dialog.txt" 2>&1 || true
          if tap_button_text "إعادة المحاولة"; then
            retry_tapped=1; retry_tap_epoch=$(date +%s)
            echo "  [$tag] retry tap SENT at +$((retry_tap_epoch - tap_epoch))s — waiting for the fresh export (wait counter reset)"
            echo "$tag timeout_dialog_retry_tapped=1 retry_tap_at_plus_s=$((retry_tap_epoch - tap_epoch))" | tee -a "$RESULT"
            sleep 5
            w=0
            continue
          else
            echo "  [$tag] retry tap FAILED (no tappable Button) — ending attempt"
            echo "$tag timeout_dialog_retry_tap=FAILED" | tee -a "$RESULT"
            outcome="retry-dialog"
            break
          fi
        fi
        echo "  [$tag] retry dialog ($DIALOG_KIND) seen at wait $w (+$(( $(date +%s) - tap_epoch ))s)"
        snap "$tag-dialog"
        cp "artifacts/ui-$tag-wait-$w.xml" "artifacts/ui-$tag-dialog.xml"
        adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-dialog.txt" 2>&1 || true
        outcome="retry-dialog"
        break
      fi
      if grep -qiE "Select a printer" "artifacts/ui-$tag-wait-$w.xml" 2>/dev/null; then outcome="print-dialog"; break; fi
      if ! alive; then
        outcome="died"
        adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-died.txt" 2>&1 || true
        grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal" "artifacts/logcat-$tag-died.txt" > "artifacts/crash-$tag.txt" 2>/dev/null || true
        break
      fi
      if [ $((w % 4)) = 0 ]; then
        adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-snap-$w.txt" 2>&1 || true
        echo "  [$tag] logcat snapshot w$w saved (+$(( $(date +%s) - tap_epoch ))s)"
      fi
      if [ $((w % 10)) = 0 ]; then echo "  [$tag] waited $((w / 2)) min, no PDF/dialog yet"; fi
    done
    echo "$tag round$round outcome=$outcome pdf=$pdfp dialog=$dialog_kind (elapsed since part tap: $(( $(date +%s) - tap_epoch ))s)" | tee -a "$RESULT"
    adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-end.txt" 2>&1 || true
    snap "$tag-end"
    if [ "$outcome" = "autosave" ]; then
      echo "$pdfp" >> artifacts/seen-pdfs.txt
      local last=-1 stable=0 sz="" gone=0 pull_dialog="none" first_nonzero_epoch=0 stable_epoch=0
      for pw in $(seq 1 60); do
        sz=$(adb -s "$DEV" shell "stat -c %s '$pdfp' 2>/dev/null" | tr -d '\r\n')
        echo "  size poll $pw: ${sz:-?}"
        if [ -z "$sz" ]; then
          gone=$((gone + 1))
          if [ "$gone" -ge 3 ]; then
            echo "  file GONE (stat failed 3x in a row) — checking dialog + liveness"
            dump_ui "$tag-filegone" >/dev/null 2>&1
            snap "$tag-filegone"
            dialog_check "artifacts/ui-$tag-filegone.xml"
            pull_dialog="$DIALOG_KIND"
            adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-filegone.txt" 2>&1 || true
            break
          fi
        else
          gone=0
          if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null && [ "$first_nonzero_epoch" = "0" ]; then first_nonzero_epoch=$(date +%s); fi
          if [ "$sz" -gt 0 ] 2>/dev/null && [ "$sz" = "$last" ]; then stable=1; stable_epoch=$(date +%s); break; fi
          last="$sz"
        fi
        sleep 10
      done
      echo "remote size: ${sz:-?} bytes (stable=$stable, gone_polls=$gone, dialog_on_gone=$pull_dialog)"
      if [ -n "$file_seen_epoch" ] && [ "$file_seen_epoch" != "0" ] && [ "$stable_epoch" != "0" ]; then
        echo "$tag write_time_s=$((stable_epoch - file_seen_epoch)) (file first seen -> stable non-zero size; first_nonzero_at_plus=$((first_nonzero_epoch - tap_epoch))s stable_at_plus=$((stable_epoch - tap_epoch))s)" | tee -a "$RESULT"
      fi
      adb -s "$DEV" logcat -d > "artifacts/logcat-$tag-afterpull.txt" 2>&1 || true
      if [ "$stable" = "1" ]; then
        adb -s "$DEV" pull "$pdfp" "artifacts/part-$tag.pdf" 2>&1 | tail -1
        if [ -s "artifacts/part-$tag.pdf" ] && head -c 5 "artifacts/part-$tag.pdf" | grep -q "%PDF-"; then
          verify_pdf_v8 "artifacts/part-$tag.pdf" "$lo" "$hi" "$tag"
          PART_VERDICT="$VERDICT"
          echo "$tag=$VERDICT spec=$VERDICT_V8" | tee -a "$RESULT"
        else
          PART_VERDICT="PULL-FAILED"
          echo "$tag=PULL-FAILED (stable=$stable, remote=$pdfp)" | tee -a "$RESULT"
        fi
        return 0
      elif [ "$gone" -ge 3 ]; then
        # v8.1: file-gone WITH a timeout dialog -> tap retry once, fresh round.
        if [ "$pull_dialog" = "timeout" ] && [ "$retry_tapped" = "0" ]; then
          echo "  [$tag] file gone + TIMEOUT dialog at +$(( $(date +%s) - tap_epoch ))s — TAPPING «إعادة المحاولة» in it (first live test of this path)"
          if tap_button_text "إعادة المحاولة"; then
            retry_tapped=1; retry_tap_epoch=$(date +%s)
            echo "$tag timeout_dialog_retry_tapped=1 retry_tap_at_plus_s=$((retry_tap_epoch - tap_epoch))" | tee -a "$RESULT"
            sed -i "\|^${pdfp}\$|d" artifacts/seen-pdfs.txt 2>/dev/null || true
            sleep 5
            round=2
            continue
          else
            echo "$tag timeout_dialog_retry_tap=FAILED" | tee -a "$RESULT"
          fi
        fi
        if [ "$pull_dialog" != "none" ]; then
          local again=""
          [ "$retry_tapped" = "1" ] && again=" (AFTER a retry tap in the same attempt)"
          PART_VERDICT="TIMEOUT-DIALOG ($pull_dialog dialog shown, file deleted at +$(( $(date +%s) - tap_epoch ))s; app alive check below)$again"
          echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
          alive && echo "$tag app_alive_after_timeout_dialog=YES" | tee -a "$RESULT" || echo "$tag app_alive_after_timeout_dialog=NO" | tee -a "$RESULT"
          echo "--- timeout markers in filegone logcat ---" | tee -a "$RESULT"
          grep -i -m 10 "onWrite\|awaitLatch\|offerRetryAfterTimeout\|printing is already\|FATAL EXCEPTION\|onRenderProcessGone" "artifacts/logcat-$tag-filegone.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
        elif grep -qiE "Select a printer" "artifacts/ui-$tag-filegone.xml" 2>/dev/null; then
          PART_VERDICT="PRINT-DIALOG-FALLBACK (file created then deleted mid-attempt; system print dialog shown)"
          echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
          alive && echo "$tag app_alive_after_print_dialog=YES" | tee -a "$RESULT" || echo "$tag app_alive_after_print_dialog=NO" | tee -a "$RESULT"
        else
          PART_VERDICT="FILE-GONE (PDF created at 0 bytes, then deleted mid-print, no dialog)"
          echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
          echo "--- deletion/cleanup markers in afterpull logcat ---" | tee -a "$RESULT"
          grep -i -m 10 "Deleted.*due to com.benabdellah\|Render process\|onServiceDisconnected\|crash wasn't handled\|onRenderProcessGone\|FATAL" "artifacts/logcat-$tag-afterpull.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
        fi
        return 0
      else
        PART_VERDICT="PULL-FAILED (stable=$stable)"
        echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
        return 0
      fi
    elif [ "$outcome" = "retry-dialog" ]; then
      PART_VERDICT="TIMEOUT-DIALOG ($dialog_kind dialog shown before any PDF appeared; app alive check below)"
      echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
      alive && echo "$tag app_alive_after_timeout_dialog=YES" | tee -a "$RESULT" || echo "$tag app_alive_after_timeout_dialog=NO" | tee -a "$RESULT"
      echo "--- timeout markers in dialog logcat ---" | tee -a "$RESULT"
      grep -i -m 10 "onWrite\|awaitLatch\|offerRetryAfterTimeout\|printing is already\|FATAL EXCEPTION\|onRenderProcessGone" "artifacts/logcat-$tag-dialog.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
      return 0
    elif [ "$outcome" = "print-dialog" ]; then
      PART_VERDICT="PRINT-DIALOG-FALLBACK"
      echo "$tag=$PART_VERDICT" | tee -a "$RESULT"
      return 0
    else
      PART_VERDICT="$outcome"
      echo "$tag=$outcome (full logcat: logcat-$tag-end.txt)" | tee -a "$RESULT"
      echo "--- renderer-death markers in $tag end logcat ---" | tee -a "$RESULT"
      grep -i -m 10 "sandboxed_process\|Renderer process.*crash\|onServiceDisconnected\|crash wasn't handled\|onRenderProcessGone\|printing is already" "artifacts/logcat-$tag-end.txt" 2>/dev/null | tee -a "$RESULT" || echo "(none)" | tee -a "$RESULT"
      return 0
    fi
    round=$((round + 1))
  done
}

# v8.6: ONLY part 5 (ch 1001-1250) — light export regression (export code
# untouched vs v8.2; one 250-ch part is the confirmation). Attempt 1 + one retry.
export_part 5 1001 1250 "a1" 10
P5A1="$PART_VERDICT"
echo "P5 attempt1=$P5A1" | tee -a "$RESULT"
if ! echo "$P5A1" | grep -q "PASS"; then
  echo "P5 attempt 1 did NOT pass ($P5A1) — one retry to separate content vs flake"
  export_part 5 1001 1250 "a2" 10
  P5A2="$PART_VERDICT"
  echo "P5 attempt2=$P5A2" | tee -a "$RESULT"
else
  P5A2="not-run"
fi

{
  echo "==================== PARTS SUMMARY (v8.6) ===================="
  echo "P5 attempt1=$P5A1 attempt2=$P5A2 (expected 250/250 ch 1001-1250; v8.2 reference: 7,324 pages = Chrome oracle)"
} | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE PARTS p5a1=$P5A1 p5a2=$P5A2"
cat "$RESULT"
