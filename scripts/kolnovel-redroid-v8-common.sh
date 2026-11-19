#!/usr/bin/env bash
# Kolnovel v8 VERIFY — shared helpers for all v8 verification jobs.
# Sourced by the kolnovel-redroid-v7-verify-*.sh scripts. Requires:
#   PKG, ACT, DEV, RESULT, V8_APK, V8_SHA (set by caller
#   before sourcing, or defaulted below). No side effects on source.
PKG="${PKG:-com.benabdellah.KolNovelApp}"
ACT="${ACT:-com.benabdellah.KolNovelApp/.MainActivity}"
DEV="${DEV:-localhost:5555}"
V8_APK="${V8_APK:-app/Kolnovel-v5.2.5-premium-v8.apk}"
V8_SHA="${V8_SHA:-18e8ffd226575b1867ccde7512e2e2c175f35c8156c7841980c968c0a0a59623}"

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
crash_excerpt() {
  grep -i -B2 -A 30 "FATAL EXCEPTION\|Fatal signal\|ANR in $PKG" "$1" > "$2" 2>/dev/null || true
}
dismiss_onboarding() {
  tap_text "Consent" || tap_text "consent" || true
  sleep 3
  tap_text "تخطي" || tap_text "التالي" || tap_text "Next" || true
  sleep 5
}
# Cold relaunch: force-stop + start + dismiss onboarding. Leaves app on home.
cold_relaunch() {
  adb -s "$DEV" shell am force-stop "$PKG" 2>&1 || true
  sleep 3
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee -a artifacts/launch.log || true
  sleep 15
  dismiss_onboarding
}
# open_novel_by_search $1=title $2=tag $3=latin query — assumes app on HOME.
# Sets OPEN_OK=1 (ok) / 2 (crashed) / 0 (never opened). Latin-only typing;
# detail verified by title + the detail-only tab "المحتوى"; card-tap retry x3.
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
# boot_redroid $1=image (default 13.0.0-latest). Sets BOOT_OK=1/0.
boot_redroid() {
  local image="${1:-redroid/redroid:13.0.0-latest}"
  sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>&1 || echo "binder modprobe FAILED"
  sudo modprobe ashmem_linux 2>&1 || echo "ashmem modprobe FAILED"
  docker pull "$image" 2>&1 | tail -3
  local mounts=""
  for d in binder hwbinder vndbinder ashmem; do
    if [ -e "/dev/$d" ]; then mounts="$mounts -v /dev/$d:/dev/$d"; fi
  done
  # shellcheck disable=SC2086
  docker run -d --privileged --name redroid $mounts -p 5555:5555 \
    "$image" androidboot.redroid_gpu_mode=guest 2>&1
  sleep 5
  BOOT_OK=0
  for i in $(seq 1 60); do
    adb connect "$DEV" >/dev/null 2>&1 || true
    if adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
      BOOT_OK=1; echo "boot_completed after ~$((i * 10))s"; break
    fi
    sleep 10
  done
  if [ "$BOOT_OK" = "1" ]; then
    echo "device: $(adb -s "$DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r') Android $(adb -s "$DEV" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r') SDK $(adb -s "$DEV" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r') abi $(adb -s "$DEV" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')" | tee -a "$RESULT"
  fi
}
# install_apk $1=apk path $2=expected sha $3=tag. Sets INSTALL_OK=1/0.
install_apk() {
  local apk="$1" sha="$2" tag="$3"
  local actual
  actual=$(sha256sum "$apk" | cut -d' ' -f1)
  echo "$tag apk sha256: $actual (expected $sha)" | tee -a "$RESULT"
  [ "$actual" = "$sha" ] && echo "$tag apk_sha=MATCH" >> "$RESULT" || echo "$tag apk_sha=MISMATCH" >> "$RESULT"
  adb -s "$DEV" shell pm clear "$PKG" 2>/dev/null || true
  adb -s "$DEV" install -r -g "$apk" 2>&1 | tee "artifacts/install-$tag.log"
  INSTALL_OK=0
  grep -q "Success" "artifacts/install-$tag.log" && INSTALL_OK=1
  echo "$tag install_ok=$INSTALL_OK" | tee -a "$RESULT"
  if [ "$INSTALL_OK" != "1" ]; then return 0; fi
  adb -s "$DEV" shell am start -W -n "$ACT" 2>&1 | tee "artifacts/launch-$tag.log" || true
  sleep 15
  snap "$tag-launch"; dump_ui "$tag-launch"
  dismiss_onboarding
  snap "$tag-home"; dump_ui "$tag-home"
}
# newest PDF in auto-save dir not seen before (paths in artifacts/seen-pdfs.txt)
new_pdf() {
  local p
  p=$(adb -s "$DEV" shell "ls -t /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n')
  if [ -n "$p" ] && ! grep -qxF "$p" artifacts/seen-pdfs.txt 2>/dev/null; then echo "$p"; fi
}
# wait_stable_pull $1=remote path $2=local dest. Waits for a stable non-zero
# size across two 10s-apart polls, then pulls. Sets STABLE=1/0, PULL_OK=1/0.
wait_stable_pull() {
  local remote="$1" dest="$2"
  local last=-1 sz="" stable=0
  for w in $(seq 1 60); do
    sz=$(adb -s "$DEV" shell "stat -c %s '$remote' 2>/dev/null" | tr -d '\r\n')
    echo "  size poll $w: ${sz:-?}"
    if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null && [ "$sz" = "$last" ]; then stable=1; break; fi
    last="$sz"
    sleep 10
  done
  STABLE="$stable"
  echo "remote size: ${sz:-?} bytes (stable=$STABLE)"
  PULL_OK=0
  if [ "$STABLE" = "1" ]; then
    adb -s "$DEV" pull "$remote" "$dest" 2>&1 | tail -1
    if [ -s "$dest" ] && head -c 5 "$dest" | grep -q "%PDF-"; then PULL_OK=1; fi
  fi
  echo "pull_ok=$PULL_OK dest=$dest"
}
# verify_pdf $1=local pdf $2=lo $3=hi $4=tag — writes artifacts/verify-$4.txt,
# sets VERDICT to "VERIFY <tag>: PASS|FAIL". Fixed heading check (per
# DIAG-REPORT §3 re-verification): strip bidi control chars, take the number
# AFTER the dash on lines containing "الفصل", plus line-anchored "N —" lines.
# PASS requires: all headings lo..hi present, FFFD=0, pages>0, Cairo present.
verify_pdf() {
  local pdf="$1" lo="$2" hi="$3" tag="$4"
  VERDICT="UNVERIFIED"
  {
    echo "=== verify $tag: $pdf (expected headings $lo-$hi) ==="
    ls -la "$pdf"
    sha256sum "$pdf"
    pdfinfo "$pdf" 2>&1 | grep -E "Pages:|Page size:|File size:"
    echo "--- fonts ---"
    pdffonts "$pdf" 2>&1
    echo "--- text extraction ---"
    pdftotext -layout "$pdf" "artifacts/text-$tag.txt" 2>&1
    ls -la "artifacts/text-$tag.txt"
  } > "artifacts/verify-$tag.txt" 2>&1
  python3 - "$tag" "$lo" "$hi" "$pdf" >> "artifacts/verify-$tag.txt" 2>&1 <<'PYEOF'
import sys, re, subprocess
tag, lo, hi, pdf = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
try:
    txt = open(f"artifacts/text-{tag}.txt", encoding="utf-8", errors="replace").read()
except Exception as e:
    print(f"VERIFY {tag}: FAIL cannot read text ({e})"); sys.exit(0)
txt = re.sub(r"[\u202a-\u202e\u200e\u200f]", "", txt)
fffd = txt.count("\ufffd")
found = set()
for line in txt.splitlines():
    if "الفصل" in line:
        for m in re.finditer(r"[-—–]\s*(\d+)", line):
            n = int(m.group(1))
            if lo <= n <= hi:
                found.add(n)
    m = re.match(r"\s*(\d+)\s*[-—–]", line)
    if m:
        n = int(m.group(1))
        if lo <= n <= hi:
            found.add(n)
expected = set(range(lo, hi + 1))
missing = sorted(expected - found)
print(f"headings found in range: {len(found)}/{len(expected)}")
print(f"missing (first 20): {missing[:20]}")
print(f"missing count: {len(missing)}")
print(f"U+FFFD replacement chars: {fffd}")
try:
    fonts = subprocess.run(["pdffonts", pdf], capture_output=True, text=True).stdout
except Exception as e:
    fonts = f"(pdffonts error: {e})"
print("--- pdffonts ---")
print(fonts)
cairo = ("Cairo-Bold" in fonts) and ("Cairo-Regular" in fonts)
print(f"Cairo-Bold+Regular present: {cairo}")
non_cairo = [l for l in fonts.splitlines() if l.strip() and "Cairo" not in l and "name" not in l.lower() and "----" not in l]
print(f"non-Cairo font lines (fallbacks for special glyphs, accepted per v6 V3): {non_cairo}")
pages = 0
try:
    out = subprocess.run(["pdfinfo", pdf], capture_output=True, text=True).stdout
    m = re.search(r"Pages:\s*(\d+)", out)
    pages = int(m.group(1)) if m else 0
except Exception:
    pass
print(f"pages: {pages}")
ok = (len(found) == len(expected) and fffd == 0 and pages > 0 and cairo)
print(f"VERIFY {tag}: {'PASS' if ok else 'FAIL'} (headings {len(found)}/{len(expected)}, fffd={fffd}, pages={pages}, cairo={cairo})")
PYEOF
  VERDICT=$(grep -oE "VERIFY $tag: (PASS|FAIL)" "artifacts/verify-$tag.txt" | tail -1 || echo "VERIFY $tag: FAIL")
  echo "$VERDICT" | tee -a "$RESULT"
}
# crash_scan — manual per-file counts (RESULT.md grep totals are misleading
# when logcats overlap; list the distinct app FATAL excerpts instead).
crash_scan() {
  {
    echo "--- crash scan (manual, per captured logcat file) ---"
    for f in artifacts/logcat-*.txt; do
      [ -f "$f" ] || continue
      n=$(grep -c "FATAL EXCEPTION" "$f" 2>/dev/null || true)
      t=$(grep -c -i "TypeError" "$f" 2>/dev/null || true)
      s=$(grep -c "Fatal signal 11" "$f" 2>/dev/null || true)
      echo "$(basename "$f"): FATAL=$n TypeError=$t SIGSEGV=$s"
    done
    echo "--- distinct app FATAL excerpts (package lines only) ---"
    grep -h -A 6 "FATAL EXCEPTION" artifacts/logcat-*.txt 2>/dev/null | grep -i "KolNovelApp\|JavascriptException\|TypeError\|SeriesListHeaderInner\|SeriesHeader" | sort -u | head -40 || echo "(none)"
  } | tee -a "$RESULT"
}
stop_redroid() {
  docker logs redroid > artifacts/redroid-docker.log 2>&1 || true
  docker rm -f redroid >/dev/null 2>&1 || true
}

# --- v8 additions ---
# delete_old_pdfs — HARNESS FIX (v7.2 VERIFY-V7.2.md §harness bug 2, proven):
# clear seen-pdfs AND delete every old PDF in Download/Kolnovel/ before
# each attempt. Clearing the seen list alone let a stale same-named file
# from a previous attempt masquerade as the new export (run 44482440401:
# part 2 "verified" against the part 3 file, 2/500 headings, 8168 pages).
delete_old_pdfs() {
  adb -s "$DEV" shell "rm -f /sdcard/Download/Kolnovel/*.pdf" 2>&1 || true
  : > artifacts/seen-pdfs.txt
  echo "old PDFs deleted + seen-pdfs cleared; remaining: $(adb -s "$DEV" shell "ls /sdcard/Download/Kolnovel/*.pdf 2>/dev/null | wc -l" | tr -d '\r ')"
}
# tap_button_text $1=exact button text — taps ONLY a clickable
# android.widget.Button with exactly this text (v7.2 retry harness fix:
# tap_text() hit the non-clickable dialog message TextView instead).
tap_button_text() {
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
    t = (node.get('text') or '').strip()
    if t == needle and node.get('class') == 'android.widget.Button' and node.get('clickable') == 'true':
        b = node.get('bounds') or ''
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1,y1,x2,y2 = map(int, m.groups())
            print((x1+x2)//2, (y1+y2)//2); sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$bounds" ] || return 1
  echo "tap_button_text: tapping Button '$needle' at $bounds"
  adb -s "$DEV" shell input tap $bounds 2>&1
  return 0
}
# verify_pdf_v8 $1=pdf $2=lo $3=hi $4=tag — runs verify_pdf (headings/Cairo/
# FFFD/pages) then the v8 reference-spec checks (DESIGN-V8 §2.3):
# Letter 612x792, Cairo-Bold body 21pt (pdftohtml -xml fontspec), margins
# ~36pt + pitch ~36.2 (pdftotext -bbox), cover = full-page image on p1,
# NO table of contents, chapter headings same size as body, ZERO rights
# markers (egypluus / t.me/ / ايجي بلس) in the FULL extracted text.
# Sets VERDICT_V8 to "VERIFY-V8 <tag>: PASS|FAIL|PARTIAL" and appends a
# summary to $RESULT. A spec failure does NOT override a headings PASS —
# both verdicts are reported separately so the coordinator can judge.
verify_pdf_v8() {
  local pdf="$1" lo="$2" hi="$3" tag="$4"
  verify_pdf "$pdf" "$lo" "$hi" "$tag"
  local base_verdict="$VERDICT"
  {
    echo "=== v8 reference-spec checks $tag: $pdf ==="
    pdfinfo "$pdf" 2>&1 | grep -E "Pages:|Page size:|Title:"
    echo "--- cover images (p1) ---"
    pdfimages -list -f 1 -l 1 "$pdf" 2>&1 | head -5
    echo "--- rights markers in FULL text (must all be 0) ---"
    grep -c -i "egypluus" "artifacts/text-$tag.txt" || true
    grep -c "t.me/" "artifacts/text-$tag.txt" || true
    grep -c "ايجي بلس" "artifacts/text-$tag.txt" || true
    grep -c "إيجي بلس" "artifacts/text-$tag.txt" || true
    echo "--- TOC marker ---"
    grep -c "المحتويات" "artifacts/text-$tag.txt" || true
    echo "--- page 2 الفصل-line count (a TOC page would list dozens) ---"
    pdftotext -f 2 -l 2 -layout "$pdf" - 2>/dev/null | grep -c "الفصل" || true
  } > "artifacts/verify-v8-$tag.txt" 2>&1
  python3 - "$tag" "$pdf" >> "artifacts/verify-v8-$tag.txt" 2>&1 <<'PYEOF'
import sys, re, subprocess
tag, pdf = sys.argv[1], sys.argv[2]
def run(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True).stdout
    except Exception as e: return ""
info = run(["pdfinfo", pdf])
m = re.search(r"Page size:\s*([\d.]+) x ([\d.]+)", info)
letter = bool(m and abs(float(m.group(1))-612) < 1 and abs(float(m.group(2))-792) < 1)
print(f"page size Letter 612x792: {letter} ({m.group(0) if m else '?'})")
title = re.search(r"Title:\s*(.*)", info)
print(f"pdf Title metadata: {title.group(1).strip() if title else '(none)'}")
txt = open(f"artifacts/text-{tag}.txt", encoding="utf-8", errors="replace").read()
rights = sum(txt.lower().count(k) for k in ["egypluus", "t.me/"]) + txt.count("ايجي بلس") + txt.count("إيجي بلس")
print(f"rights markers total in full text: {rights} (egypluus={txt.lower().count('egypluus')} t.me/={txt.count('t.me/')})")
toc = txt.count("المحتويات")
print(f"TOC marker 'المحتويات' occurrences: {toc}")
# body font size via pdftohtml -xml on a content page (page 50 if present)
pages = int(re.search(r"Pages:\s*(\d+)", info).group(1)) if re.search(r"Pages:\s*(\d+)", info) else 0
probe = min(pages, 50) if pages >= 50 else min(pages, 3)
subprocess.run(["pdftohtml", "-xml", "-f", str(probe), "-l", str(probe), pdf, "/tmp/v8probe"], capture_output=True)
try: xml = open("/tmp/v8probe.xml", encoding="utf-8", errors="replace").read()
except Exception as e: xml = ""
sizes = {}
for mm in re.finditer(r'<fontspec id="(\d+)" size="([\d.]+)"[^>]*family="([^"]+)"', xml):
    sizes[mm.group(1)] = (float(mm.group(2)), mm.group(3))
body21 = any(sz == 21 and "Cairo-Bold" in fam for sz, fam in sizes.values())
print(f"content page {probe} fontspecs: {sizes}")
print(f"body font Cairo-Bold 21pt on p{probe}: {body21}")
# margins + pitch via pdftotext -bbox on the same page
bbox = run(["pdftotext", "-bbox", "-f", str(probe), "-l", str(probe), pdf, "-"])
words = re.findall(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)"', bbox)
if words:
    xs = [float(w[0]) for w in words]; xe = [float(w[2]) for w in words]
    ys = sorted(set(round(float(w[1]), 1) for w in words))
    gaps = [round(b-a, 1) for a, b in zip(ys, ys[1:]) if 20 < b-a < 80]
    from collections import Counter
    pitch = Counter(gaps).most_common(1)[0][0] if gaps else None
    print(f"bbox p{probe}: xMin={min(xs):.1f} xMax={max(xe):.1f} firstY={ys[0]:.1f} pitch(most common gap)={pitch}")
else:
    print(f"bbox p{probe}: no words parsed")
# cover image: pdfimages -list p1
imgs = run(["pdfimages", "-list", "-f", "1", "-l", "1", pdf])
print("pdfimages p1:"); print(imgs)
checks = {"letter": letter, "body21": body21, "rights0": rights == 0, "toc0": toc == 0}
failed = [k for k, v in checks.items() if not v]
print(f"VERIFY-V8 {tag}: {'PASS' if not failed else 'FAIL (' + ','.join(failed) + ')'} (spec checks: {checks})")
PYEOF
  VERDICT_V8=$(grep -oE "VERIFY-V8 $tag: (PASS|FAIL.*)" "artifacts/verify-v8-$tag.txt" | tail -1 || echo "VERIFY-V8 $tag: FAIL")
  echo "base=$base_verdict spec=$VERDICT_V8" | tee -a "$RESULT"
}
