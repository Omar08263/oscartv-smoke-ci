#!/usr/bin/env bash
# Kolnovel v7 VERIFY job 1 — A/B crash matrix (MAIN GATE).
# 3 rounds x 4 cold opens of 38916 via search (Latin "Reverend"):
#   12 opens v7 + 12 opens v3 (stock-header control).
# Each open is from a cold launch (force-stop + relaunch). Detail verified by
# title + "المحتوى" tab. In each round, after v7 cycle 4 opens OK, ONE tap on
# "تصدير PDF" must start PdfExportActivity (press test, 1 per round = 3 total).
# A crash = app process dead, or a FATAL EXCEPTION / SIGSEGV / JS TypeError
# for our package in the cycle logcat. ANY JS/native crash in 21721/21728 =
# mitigation failure — recorded with the verbatim logcat lines, never hidden.
# RESULT lines: "R<r> <apk> C<c>: OK|CRASH|MISS [detail]" — one per cycle.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v7-common.sh
source scripts/kolnovel-redroid-v7-common.sh

TITLE="القس المجنون"
V7_CRASHES=0; V7_OK=0; V7_MISS=0
V3_CRASHES=0; V3_OK=0; V3_MISS=0
PRESS_OK=0; PRESS_FAIL=0

echo "== host =="
uname -m; nproc; free -h | head -2
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi

# press_test $1=round — assumes detail page open, button in top dump.
press_test() {
  local round="$1"
  echo "== R$round press test: tap 'تصدير PDF' =="
  adb -s "$DEV" logcat -c 2>&1 || true
  if ! grep -q "تصدير PDF" artifacts/ui-r${round}v7c4-detail-top.xml 2>/dev/null; then
    echo "R$round press=SKIPPED (button not in top dump)" | tee -a "$RESULT"
    PRESS_FAIL=$((PRESS_FAIL + 1)); return 0
  fi
  if ! tap_text "تصدير PDF"; then
    echo "R$round press=TAP-FAILED (no tappable node)" | tee -a "$RESULT"
    PRESS_FAIL=$((PRESS_FAIL + 1)); return 0
  fi
  echo "R$round press: tap sent"
  local started=0 chooser=0 crashed=0
  for w in $(seq 1 9); do
    sleep 10
    adb -s "$DEV" logcat -d > "artifacts/logcat-r${round}-press.txt" 2>&1 || true
    if grep -q "PdfExportActivity" "artifacts/logcat-r${round}-press.txt" 2>/dev/null; then started=1; fi
    dump_ui "r${round}-press-w$w" >/dev/null 2>&1
    if grep -qi "اختر الجزء" "artifacts/ui-r${round}-press-w$w.xml" 2>/dev/null; then chooser=1; fi
    if ! alive; then crashed=1; break; fi
    if [ "$started" = "1" ]; then break; fi
  done
  snap "r${round}-press-aftertap"; dump_ui "r${round}-press-aftertap"
  adb -s "$DEV" logcat -d > "artifacts/logcat-r${round}-press.txt" 2>&1 || true
  grep -i "PdfExportActivity" "artifacts/logcat-r${round}-press.txt" | head -10 > "artifacts/r${round}-press-start-lines.txt" || true
  echo "R$round press: started=$started chooser=$chooser crashed=$crashed" | tee -a "$RESULT"
  cat "artifacts/r${round}-press-start-lines.txt" | tee -a "$RESULT"
  if [ "$crashed" = "1" ]; then
    crash_excerpt "artifacts/logcat-r${round}-press.txt" "artifacts/crash-r${round}-press.txt"
    echo "R$round press=CRASH" | tee -a "$RESULT"
    PRESS_FAIL=$((PRESS_FAIL + 1))
  elif [ "$started" = "1" ]; then
    echo "R$round press=PASS (PdfExportActivity started, chooser=$chooser)" | tee -a "$RESULT"
    PRESS_OK=$((PRESS_OK + 1))
  else
    echo "R$round press=NO-START-IN-90S" | tee -a "$RESULT"
    PRESS_FAIL=$((PRESS_FAIL + 1))
  fi
}

# test_apk_cycles $1=apk $2=sha $3=tag(v7|v3) $4=round
test_apk_cycles() {
  local apk="$1" sha="$2" tag="$3" round="$4"
  install_apk "$apk" "$sha" "$tag-r$round"
  if [ "$INSTALL_OK" != "1" ]; then
    echo "R$round $tag: INSTALL FAILED — 4 cycles recorded as MISS" | tee -a "$RESULT"
    for c in 1 2 3 4; do echo "R$round $tag C$c: MISS (install failed)" >> "$RESULT"; done
    if [ "$tag" = "v7" ]; then V7_MISS=$((V7_MISS + 4)); else V3_MISS=$((V3_MISS + 4)); fi
    return 0
  fi
  for c in 1 2 3 4; do
    echo "########## R$round $tag cycle $c (cold open via search) ##########"
    # Cycle 1 follows the install launch (already cold); cycles 2-4 relaunch cold.
    if [ "$c" != "1" ]; then cold_relaunch; fi
    adb -s "$DEV" logcat -c 2>&1 || true
    open_novel_by_search "$TITLE" "r${round}${tag}c${c}" "Reverend"
    local verdict="MISS"
    if [ "$OPEN_OK" = "1" ]; then verdict="OK"
    elif [ "$OPEN_OK" = "2" ]; then verdict="CRASH"
    fi
    local btn="button=?"
    if [ "$OPEN_OK" = "1" ]; then
      if grep -q "تصدير PDF" "artifacts/ui-r${round}${tag}c${c}-detail-top.xml" 2>/dev/null; then btn="button=visible-top"; else btn="button=absent-top"; fi
    fi
    echo "R$round $tag C$c: $verdict [$btn]" | tee -a "$RESULT"
    if [ "$OPEN_OK" = "2" ]; then
      echo "--- verbatim crash lines (R$round $tag C$c) ---" | tee -a "$RESULT"
      grep -i -m 5 -A 12 "FATAL EXCEPTION" "artifacts/logcat-r${round}${tag}c${c}-open.txt" 2>/dev/null | tee -a "$RESULT" || true
      if [ "$tag" = "v7" ]; then V7_CRASHES=$((V7_CRASHES + 1)); else V3_CRASHES=$((V3_CRASHES + 1)); fi
    elif [ "$OPEN_OK" = "1" ]; then
      if [ "$tag" = "v7" ]; then V7_OK=$((V7_OK + 1)); else V3_OK=$((V3_OK + 1)); fi
    else
      if [ "$tag" = "v7" ]; then V7_MISS=$((V7_MISS + 1)); else V3_MISS=$((V3_MISS + 1)); fi
    fi
    # Press test: once per round, on v7 cycle 4, after a successful open.
    if [ "$tag" = "v7" ] && [ "$c" = "4" ] && [ "$OPEN_OK" = "1" ]; then
      press_test "$round"
    fi
  done
}

for r in 1 2 3; do
  echo "==================== ROUND $r ===================="
  test_apk_cycles "$V7_APK" "$V7_SHA" "v7" "$r"
  test_apk_cycles "$V3_APK" "$V3_SHA" "v3" "$r"
done

{
  echo "==================== A/B SUMMARY ===================="
  echo "v7: crashes=$V7_CRASHES ok=$V7_OK miss=$V7_MISS / 12"
  echo "v3: crashes=$V3_CRASHES ok=$V3_OK miss=$V3_MISS / 12"
  echo "press: ok=$PRESS_OK fail=$PRESS_FAIL / 3"
  if [ "$V7_CRASHES" = "0" ] && [ "$V7_OK" = "12" ] && [ "$PRESS_OK" = "3" ]; then
    echo "AB_VERDICT=PASS (0/12 v7 crashes, 12/12 opens OK, 3/3 presses OK)"
  elif [ "$V7_CRASHES" = "0" ]; then
    echo "AB_VERDICT=PARTIAL (0 v7 crashes BUT ok=$V7_OK/12 miss=$V7_MISS press_ok=$PRESS_OK/3 — see per-cycle lines)"
  else
    echo "AB_VERDICT=FAIL (v7 crashes=$V7_CRASHES/12 — mitigation FAILED)"
  fi
} | tee -a "$RESULT"
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE AB v7_crashes=$V7_CRASHES v3_crashes=$V3_CRASHES press_ok=$PRESS_OK/3"
cat "$RESULT"
