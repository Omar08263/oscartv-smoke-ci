#!/usr/bin/env python3
"""Tap the first movie item on the OscarTV home screen, wait, capture the
detail / [D7] error screen. Best-effort: never fails the job; writes
artifacts/detail-check.txt with what it did and what the resulting UI dump
contains (D7 markers: TOK= / HOST= / IP= / ANON= / error code).
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

OUT = "artifacts/detail-check.txt"
NAV_WORDS = ["الرئيسية", "بحث", "المفضلة", "الملف", "حساب", "بروفايل",
             "الإعدادات", "Settings", "Profile", "Search", "Home",
             "تسجيل", "دخول", "خروج", "إعلانات", "بريميوم"]
ITEM_HINTS = ["item", "poster", "movie", "series", "card", "cover",
              "thumb", "film", "banner", "poster", "title", "name"]

log = []


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout + r.stderr


def bounds_of(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds") or "")
    if not m:
        return None
    return tuple(map(int, m.groups()))


def center(b):
    x1, y1, x2, y2 = b
    return (x1 + x2) // 2, (y1 + y2) // 2


def pick_candidate(path):
    """Return (x, y, reason) for the best movie-item tap, or None."""
    try:
        tree = ET.parse(path)
    except Exception as e:
        log.append(f"cannot parse {path}: {e}")
        return None
    nodes = list(tree.iter("node"))
    if not nodes:
        log.append(f"{path}: no nodes in dump")
        return None
    # v13-r2 lesson: if the screen is a SYSTEM ANR dialog ("... isn't
    # responding" with Close app / Wait), do NOT tap anything — the only
    # clickables are the dialog's buttons, not movie items.
    for n in nodes:
        t = (n.get("text") or "") + " " + (n.get("content-desc") or "")
        if "isn't responding" in t:
            log.append(f"SYSTEM ANR DIALOG on screen ({t.strip()!r}) — refusing to tap")
            globals()["ANR_ON_SCREEN"] = True
            return None
    # Screen height from the largest bounds seen (fallback 2400)
    max_y = 0
    for n in nodes:
        b = bounds_of(n)
        if b:
            max_y = max(max_y, b[3])
    H = max_y if max_y > 1000 else 2400
    log.append(f"{path}: {len(nodes)} nodes, screen height ~{H}")
    clickables = []
    for n in nodes:
        if n.get("clickable") != "true":
            continue
        b = bounds_of(n)
        if not b:
            continue
        x1, y1, x2, y2 = b
        w, h = x2 - x1, y2 - y1
        if w < 40 or h < 40:
            continue
        text = ((n.get("text") or "") + " " + (n.get("content-desc") or "")
                + " " + (n.get("resource-id") or "")).strip()
        clickables.append((n, b, text))
    log.append(f"clickable nodes (>=40px): {len(clickables)}")
    # Exclude bottom nav (bottom 12% of screen) and top bar (top 8%)
    content = [(n, b, t) for (n, b, t) in clickables
               if b[1] > H * 0.08 and b[3] < H * 0.88]
    # Exclude nav/profile words
    content = [(n, b, t) for (n, b, t) in content
               if not any(w in t for w in NAV_WORDS)]
    log.append(f"content-region non-nav clickables: {len(content)}")
    if not content:
        return None
    # Prefer nodes whose id/text hints at a poster/item, largest area first
    def score(item):
        n, b, t = item
        x1, y1, x2, y2 = b
        area = (x2 - x1) * (y2 - y1)
        hint = 1 if any(h in t.lower() for h in ITEM_HINTS) else 0
        # prefer upper rows (smaller y) among equals
        return (hint, area, -y1)
    content.sort(key=score, reverse=True)
    n, b, t = content[0]
    c = center(b)
    return c[0], c[1], f"bounds={b} text/id={t!r} class={n.get('class')}"


def pull_retry(src, dst):
    """adb pull with 3 attempts; v13 run proved a silent pull failure can
    lose the only copy of a dump/screenshot."""
    for i in (1, 2, 3):
        r = subprocess.run(f"adb pull {src} {dst}", shell=True,
                           capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        if out:
            log.append(f"pull {src} attempt {i}: {out[:200]}")
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            return True
        time.sleep(5)
    log.append(f"pull {src} FAILED after 3 attempts")
    return False


def capture(tag):
    # screenshot straight to host (no on-device file + pull round-trip)
    with open(f"artifacts/{tag}.png", "wb") as f:
        subprocess.run(f"adb exec-out screencap -p", shell=True, stdout=f,
                       stderr=subprocess.DEVNULL)
    if not (os.path.exists(f"artifacts/{tag}.png")
            and os.path.getsize(f"artifacts/{tag}.png") > 0):
        log.append(f"exec-out screencap empty for {tag}, fallback to file+pull")
        run(f"adb shell screencap -p /sdcard/{tag}.png")
        pull_retry(f"/sdcard/{tag}.png", f"artifacts/{tag}.png")
    run(f"adb shell uiautomator dump /sdcard/ui-{tag}.xml")
    pull_retry(f"/sdcard/ui-{tag}.xml", f"artifacts/ui-{tag}.xml")
    if not (os.path.exists(f"artifacts/ui-{tag}.xml")
            and os.path.getsize(f"artifacts/ui-{tag}.xml") > 0):
        time.sleep(5)
        run(f"adb shell uiautomator dump /sdcard/ui-{tag}.xml")
        pull_retry(f"/sdcard/ui-{tag}.xml", f"artifacts/ui-{tag}.xml")


def grep_d7(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            data = f.read()
    except FileNotFoundError:
        return ["dump not present"]
    hits = []
    for pat in ["خطأ", "تعذّر", "TOK=", "HOST=", "IP=", "ANON=",
                "429", "403", "UnknownHost", "بريميوم", "2099", "2100"]:
        if pat in data:
            hits.append(pat)
    # Extract the [D7] line if present
    m = re.search(r"[^\n]*TOK=[^\n]*", data)
    if m:
        hits.append("D7-LINE: " + m.group(0).strip()[:300])
    m2 = re.search(r"[^\n]*ANON=[^\n]*", data)
    if m2 and (not m or m2.group(0) != m.group(0)):
        hits.append("ANON-LINE: " + m2.group(0).strip()[:300])
    return hits if hits else ["no D7/error markers"]


def main():
    src = "artifacts/ui-home2.xml"
    if not os.path.exists(src):
        src = "artifacts/ui-home.xml"
    log.append(f"using UI dump: {src}")
    cand = pick_candidate(src) if os.path.exists(src) else None
    if cand:
        x, y, reason = cand
        log.append(f"tapping movie item at ({x},{y}): {reason}")
        run(f"adb shell input tap {x} {y}")
    elif globals().get("ANR_ON_SCREEN"):
        log.append("no tap: system ANR dialog on screen (fallback tap skipped)")
    else:
        log.append("no movie item found; fallback tap at screen centre (540,900)")
        run("adb shell input tap 540 900")
    time.sleep(15)
    capture("detail")
    log.append("captured detail screen after 15s")
    log.append("foreground after detail tap:")
    fg = run("adb shell dumpsys activity activities | grep -i 'mResumedActivity\\|mFocusedApp' | head -4")
    log.append(fg.strip() or "(no foreground info)")
    with open("artifacts/foreground.txt", "a", encoding="utf-8") as f:
        f.write("\n== after detail tap ==\n" + fg)
    log.append(f"ui-detail.xml markers: {grep_d7('artifacts/ui-detail.xml')}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(log) + "\n")
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    sys.exit(main())
