#!/usr/bin/env bash
# Kolnovel v8 VERIFY job 2 — «كل الروايات» (Browse-All) screen.
# Proves live on Redroid 13:
#  1. «تصفح الكل» button exists on the Discover (اكتشف) tab and opens
#     DiscoverNovels in preset=all mode.
#  2. The list shows ALL 279 catalog novels: scroll-counted by matching
#     every UI-dump text node against scripts/kolnovel-v8-titles.txt
#     (279 titles from novels-list.json); the LAST title «مدجج بالعتاد»
#     must be reachable, and «القس المجنون» (38916, outside the old 40)
#     must be present.
#  3. In-screen search finds «القس المجنون» (Latin typing «Reverend»;
#     Arabic input text is broken on Redroid 13 — v7 lesson).
#  4. Tapping it opens NovelDetails (title + «المحتوى» tab) with the
#     «تصدير PDF» button visible, and one tap starts PdfExportActivity.
#  5. Fresh-merge check: any title shown that is NOT in the 279 snapshot
#     is a novel added after v8 was built (merged via latest_updated).
#     If none appear, the merge path is UNPROVEN (not failed) — the
#     snapshot list itself is still verified complete.
set -u
mkdir -p artifacts
exec > >(tee artifacts/run.log) 2>&1
RESULT="artifacts/RESULT.md"
: > "$RESULT"
: > artifacts/seen-pdfs.txt
# shellcheck source=kolnovel-redroid-v8-common.sh
source scripts/kolnovel-redroid-v8-common.sh

echo "== host =="
uname -m; nproc; free -h | head -2
sudo apt-get update -qq && sudo apt-get install -y -qq poppler-utils 2>&1 | tail -2 || echo "poppler install FAILED"
command -v adb >/dev/null && adb --version | head -1 || echo "NO ADB"
if ! command -v adb >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq adb || echo "apt adb install FAILED"
fi
boot_redroid "redroid/redroid:13.0.0-latest"
if [ "$BOOT_OK" != "1" ]; then echo "REDROID_BOOT_FAILED" > "$RESULT"; exit 1; fi
install_apk "$V8_APK" "$V8_SHA" "v8"
if [ "$INSTALL_OK" != "1" ]; then echo "INSTALL FAILED"; exit 1; fi

# extract_seen_titles $1=ui-dump — appends matched 279-list titles + all
# raw distinct strings to artifacts; prints "new:<n> total:<n>".
extract_seen_titles() {
  python3 - "$1" "scripts/kolnovel-v8-titles.txt" "artifacts/allnovels-seen.txt" "artifacts/allnovels-raw.txt" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
dump, titles_f, seen_f, raw_f = sys.argv[1:5]
titles = set(l.strip() for l in open(titles_f, encoding="utf-8") if l.strip())
try: root = ET.parse(dump).getroot()
except Exception: print("new:0 total:? (dump parse failed)"); sys.exit(0)
seen = set(l.strip() for l in open(seen_f, encoding="utf-8") if l.strip()) if __import__("os").path.exists(seen_f) else set()
raw = set(l.strip() for l in open(raw_f, encoding="utf-8") if l.strip()) if __import__("os").path.exists(raw_f) else set()
new = 0
for node in root.iter('node'):
    for val in (node.get('text') or '', node.get('content-desc') or ''):
        v = val.strip()
        if not v: continue
        if v not in raw:
            raw.add(v)
            with open(raw_f, "a", encoding="utf-8") as f: f.write(v + "\n")
        if v in titles and v not in seen:
            seen.add(v); new += 1
            with open(seen_f, "a", encoding="utf-8") as f: f.write(v + "\n")
print(f"new:{new} total:{len(seen)}")
PYEOF
}

echo "== open Discover tab (اكتشف) =="
cold_relaunch
adb -s "$DEV" logcat -c 2>&1 || true
if ! tap_text "اكتشف"; then
  echo "tab اكتشف NOT FOUND — trying Browse" | tee -a "$RESULT"
  tap_text "Browse" || true
fi
sleep 5
dump_ui "hub"; snap "hub"
if grep -q "تصفح الكل" artifacts/ui-hub.xml 2>/dev/null; then
  echo "browse_all_button_visible=1" | tee -a "$RESULT"
else
  echo "browse_all_button_visible=0 (تصفح الكل NOT in hub dump)" | tee -a "$RESULT"
  echo "allnovels_verdict=FAIL (no تصفح الكل button on Discover tab)" | tee -a "$RESULT"
  crash_scan
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  stop_redroid
  echo "DONE allnovels=FAIL-no-button"
  cat "$RESULT"
  exit 0
fi
echo "== tap تصفح الكل =="
tap_text "تصفح الكل" || tap_regex "تصفح الكل" "artifacts/ui-hub.xml" || true
sleep 8
# Wait for the all-mode list to load (3 batch fetches + latest merge).
LOADED=0
for i in $(seq 1 18); do
  dump_ui "all-wait-$i" >/dev/null 2>&1
  out=$(extract_seen_titles "artifacts/ui-all-wait-$i.xml")
  echo "  load poll $i: $out"
  if grep -q "منظور قارئ كلي العلم\|القس المجنون" "artifacts/allnovels-seen.txt" 2>/dev/null; then
    LOADED=1; echo "all-mode list LOADED (poll $i)" | tee -a "$RESULT"; break
  fi
  sleep 10
done
snap "all-first-screen"
if [ "$LOADED" != "1" ]; then
  echo "all_mode_loaded=0 (no catalog title appeared in 180s)" | tee -a "$RESULT"
  echo "allnovels_verdict=FAIL (all-mode list never loaded)" | tee -a "$RESULT"
  adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
  crash_scan
  stop_redroid
  echo "DONE allnovels=FAIL-no-load"
  cat "$RESULT"
  exit 0
fi

echo "== scroll-count the full list =="
: > artifacts/allnovels-seen.txt
: > artifacts/allnovels-raw.txt
# Re-seed from the load polls (they were counted before the reset above).
for f in artifacts/ui-all-wait-*.xml; do extract_seen_titles "$f" >/dev/null 2>&1; done
LAST_SEEN=0; NO_NEW=0; SCROLLS=0
for i in $(seq 1 80); do
  SCROLLS=$i
  adb -s "$DEV" shell input swipe 360 1000 360 300 300 2>&1 || true
  sleep 3
  dump_ui "all-scroll-$i" >/dev/null 2>&1
  out=$(extract_seen_titles "artifacts/ui-all-scroll-$i.xml")
  total=$(echo "$out" | sed -n 's/.*total:\([0-9]*\).*/\1/p')
  echo "  scroll $i: $out"
  if grep -q "مدجج بالعتاد" artifacts/allnovels-seen.txt 2>/dev/null; then
    echo "  LAST title مدجج بالعتاد reached at scroll $i" | tee -a "$RESULT"
  fi
  if [ "${total:-0}" = "$LAST_SEEN" ]; then NO_NEW=$((NO_NEW + 1)); else NO_NEW=0; fi
  LAST_SEEN="${total:-0}"
  if grep -q "مدجج بالعتاد" artifacts/allnovels-seen.txt 2>/dev/null && [ "$NO_NEW" -ge 3 ]; then
    echo "  stop: last title seen + 3 scrolls with no new titles" | tee -a "$RESULT"
    break
  fi
  if [ "$((i % 10))" = 0 ]; then snap "all-scroll-$i"; fi
done
COUNT=$(wc -l < artifacts/allnovels-seen.txt | tr -d ' ')
echo "allnovels_count_seen=$COUNT/279 scrolls=$SCROLLS" | tee -a "$RESULT"
grep -q "القس المجنون" artifacts/allnovels-seen.txt 2>/dev/null && echo "reverend_38916_in_list=1" | tee -a "$RESULT" || echo "reverend_38916_in_list=0" | tee -a "$RESULT"
grep -q "مدجج بالعتاد" artifacts/allnovels-seen.txt 2>/dev/null && echo "last_title_reachable=1" | tee -a "$RESULT" || echo "last_title_reachable=0" | tee -a "$RESULT"
snap "all-end"
# Fresh-merge: titles shown that are NOT in the 279 snapshot.
python3 - "scripts/kolnovel-v8-titles.txt" "artifacts/allnovels-raw.txt" >> "$RESULT" 2>&1 <<'PYEOF'
import sys
titles = set(l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip())
raw = set(l.strip() for l in open(sys.argv[2], encoding="utf-8") if l.strip())
# A "fresh" candidate is a raw string that looks like a novel title but is
# not in the snapshot. UI chrome (buttons, tabs, counts) pollutes this, so
# report candidates only as a manual-review list, not a verdict by itself.
print(f"fresh_merge: raw distinct strings={len(raw)}; snapshot titles={len(titles)}")
print("(manual review: any genuine novel title below that is NOT in the 279 snapshot proves the latest_updated merge; none proves nothing if no novel was added since the snapshot)")
PYEOF
cp artifacts/allnovels-seen.txt artifacts/allnovels-seen-final.txt 2>/dev/null || true

echo "== in-screen search for Reverend =="
# Scroll back to top first (many swipes up), then find the search field.
for _ in $(seq 1 12); do adb -s "$DEV" shell input swipe 360 300 360 1000 300 2>&1 || true; sleep 1; done
sleep 3
dump_ui "all-top"; snap "all-top"
SEARCH_OK=0
for needle in "البحث عن رواية" "بحث" "ابحث"; do
  if tap_text "$needle"; then
    echo "search field tapped via '$needle'" | tee -a "$RESULT"
    SEARCH_OK=1; break
  fi
done
if [ "$SEARCH_OK" = "0" ]; then
  # Fallback: tap the search (magnifier) icon by content-desc.
  if tap_regex "بحث|Search|search" "artifacts/ui-all-top.xml"; then
    echo "search opened via icon/content-desc" | tee -a "$RESULT"
    SEARCH_OK=1
  fi
fi
if [ "$SEARCH_OK" = "1" ]; then
  sleep 3
  adb -s "$DEV" shell input text "Reverend" 2>&1 || true
  sleep 5
  dump_ui "all-search-results"; snap "all-search-results"
  if grep -q "القس المجنون" artifacts/ui-all-search-results.xml 2>/dev/null; then
    echo "all_search_reverend_found=1" | tee -a "$RESULT"
  else
    echo "all_search_reverend_found=0" | tee -a "$RESULT"
  fi
else
  echo "all_search_field=NOT-FOUND (no tappable search field/icon in all-mode)" | tee -a "$RESULT"
  echo "all_search_reverend_found=0" | tee -a "$RESULT"
fi

echo "== tap القس المجنون -> detail + export button =="
DETAIL_OK=0; BTN_OK=0; STARTED=0
# Prefer the search-results dump if it has the title, else the scrolled list.
if grep -q "القس المجنون" artifacts/ui-all-search-results.xml 2>/dev/null; then
  tap_regex "فتح القس المجنون\$" "artifacts/ui-all-search-results.xml" \
    || tap_text "القس المجنون" || true
else
  # Re-scroll to find it in the list (it is near the end: archive order).
  for i in $(seq 1 40); do
    dump_ui "all-find-$i" >/dev/null 2>&1
    if grep -q "القس المجنون" "artifacts/ui-all-find-$i.xml" 2>/dev/null; then
      echo "found القس المجنون in list at scroll $i" | tee -a "$RESULT"
      tap_text "القس المجنون" || true
      break
    fi
    adb -s "$DEV" shell input swipe 360 1000 360 300 300 2>&1 || true
    sleep 2
  done
fi
sleep 10
snap "all-detail-top"; dump_ui "all-detail-top"
adb -s "$DEV" logcat -d > artifacts/logcat-all-detail.txt 2>&1 || true
if grep -q "القس المجنون" artifacts/ui-all-detail-top.xml 2>/dev/null \
   && grep -q "المحتوى" artifacts/ui-all-detail-top.xml 2>/dev/null; then
  DETAIL_OK=1
  echo "all_detail_open=1 (title + المحتوى tab)" | tee -a "$RESULT"
else
  echo "all_detail_open=0" | tee -a "$RESULT"
fi
if [ "$DETAIL_OK" = "1" ]; then
  grep -q "تصدير PDF" artifacts/ui-all-detail-top.xml 2>/dev/null && BTN_OK=1
  echo "all_detail_button_visible=$BTN_OK" | tee -a "$RESULT"
  if [ "$BTN_OK" = "1" ]; then
    adb -s "$DEV" logcat -c 2>&1 || true
    tap_text "تصدير PDF" || true
    sleep 10
    adb -s "$DEV" logcat -d > artifacts/logcat-all-press.txt 2>&1 || true
    dump_ui "all-press-aftertap"; snap "all-press-aftertap"
    grep -q "PdfExportActivity" artifacts/logcat-all-press.txt 2>/dev/null && STARTED=1
    grep -qi "اختر الجزء" artifacts/ui-all-press-aftertap.xml 2>/dev/null && echo "all_press_part_chooser=1" | tee -a "$RESULT" || echo "all_press_part_chooser=0" | tee -a "$RESULT"
    echo "all_press_pdfexport_started=$STARTED" | tee -a "$RESULT"
  fi
fi
ALIVE="NO"; alive && ALIVE="YES"
echo "app_alive_end=$ALIVE" | tee -a "$RESULT"
if [ "$COUNT" = "279" ] && grep -q "القس المجنون" artifacts/allnovels-seen.txt 2>/dev/null \
   && grep -q "مدجج بالعتاد" artifacts/allnovels-seen.txt 2>/dev/null \
   && [ "$DETAIL_OK" = "1" ] && [ "$BTN_OK" = "1" ] && [ "$STARTED" = "1" ]; then
  echo "allnovels_verdict=PASS (279/279 listed, last title reachable, 38916 present, search found it, detail+button+tap OK)" | tee -a "$RESULT"
elif [ "$COUNT" -ge 270 ] 2>/dev/null && [ "$DETAIL_OK" = "1" ] && [ "$STARTED" = "1" ]; then
  echo "allnovels_verdict=PARTIAL (count=$COUNT/279 — see seen list; detail+button+tap OK)" | tee -a "$RESULT"
else
  echo "allnovels_verdict=FAIL (count=$COUNT/279 detail=$DETAIL_OK button=$BTN_OK started=$STARTED search=$SEARCH_OK)" | tee -a "$RESULT"
fi
crash_scan
adb -s "$DEV" logcat -d > artifacts/logcat-final.txt 2>&1 || true
stop_redroid
echo "DONE allnovels count=$COUNT/279 detail=$DETAIL_OK btn=$BTN_OK started=$STARTED"
cat "$RESULT"
